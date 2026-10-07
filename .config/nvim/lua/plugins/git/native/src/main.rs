// Structural search adapted from Difftastic 0.71.0 (MIT).
// See ../../THIRD_PARTY_NOTICES.md in the plugin root.
// The Lua renderer owns preprocessing, syntax colors and span projection.
use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashMap};
use std::io::{self, Read, Write};

const NONE: u32 = u32::MAX;
const MAX_INPUT: usize = 64 * 1024 * 1024;
#[derive(Default)]
struct Node {
    content: u32,
    depth: u32,
    child: u32,
    next: u32,
    kind: u32,
    list: bool,
    punctuation: bool,
    text: Vec<u8>,
    open: Vec<u8>,
    close: Vec<u8>,
}
struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
}
impl<'a> Reader<'a> {
    fn bytes(&mut self, n: usize) -> Result<&'a [u8], String> {
        let end = self.pos.checked_add(n).ok_or("length overflow")?;
        let value = self.data.get(self.pos..end).ok_or("truncated request")?;
        self.pos = end;
        Ok(value)
    }
    fn u32(&mut self) -> Result<u32, String> {
        Ok(u32::from_le_bytes(self.bytes(4)?.try_into().unwrap()))
    }
    fn text(&mut self) -> Result<Vec<u8>, String> {
        let n = self.u32()? as usize;
        Ok(self.bytes(n)?.to_vec())
    }
    fn nodes(&mut self, count: u32) -> Result<Vec<Node>, String> {
        if count == 0 || count > 3_000_000 {
            return Err("invalid node count".into());
        }
        let mut nodes = Vec::with_capacity(count as usize + 1);
        nodes.push(Node::default());
        for _ in 0..count {
            let node = Node {
                content: self.u32()?,
                depth: self.u32()?,
                child: self.u32()?,
                next: self.u32()?,
                kind: self.u32()?,
                list: self.u32()? != 0,
                punctuation: self.u32()? != 0,
                text: self.text()?,
                open: self.text()?,
                close: self.text()?,
            };
            if node.child > count || node.next > count || node.kind > 3 {
                return Err("invalid node reference".into());
            }
            nodes.push(node);
        }
        Ok(nodes)
    }
}
// Match Lua's byte-pattern UTF-8 chunks, including its behavior on malformed
// source bytes; replacement characters would change literal similarity.
fn characters(text: &[u8]) -> Vec<&[u8]> {
    let mut chars = Vec::new();
    let mut i = 0;
    while i < text.len() {
        let first = i;
        let byte = text[i];
        i += 1;
        if byte <= 127 || (194..=244).contains(&byte) {
            while i < text.len() && (128..=191).contains(&text[i]) {
                i += 1;
            }
            chars.push(&text[first..i]);
        }
    }
    chars
}
fn similarity(a: &[u8], b: &[u8]) -> u32 {
    let a = characters(a);
    let b = characters(b);
    let total = a.len().max(b.len()).max(1);
    let mut first = 0;
    let mut end_a = a.len();
    let mut end_b = b.len();
    while first < end_a && first < end_b && a[first] == b[first] {
        first += 1;
    }
    while end_a > first && end_b > first && a[end_a - 1] == b[end_b - 1] {
        end_a -= 1;
        end_b -= 1;
    }
    let a = &a[first..end_a];
    let b = &b[first..end_b];
    let distance = if a.is_empty() || b.is_empty() {
        a.len().max(b.len())
    } else {
        let mut row: Vec<usize> = (0..=b.len()).collect();
        for (i, x) in a.iter().enumerate() {
            let mut previous = row[0];
            row[0] = i + 1;
            for (j, y) in b.iter().enumerate() {
                let current = row[j + 1];
                row[j + 1] = (current + 1)
                    .min(row[j] + 1)
                    .min(previous + usize::from(x != y));
                previous = current;
            }
        }
        row[b.len()]
    };
    (100.0 * (1.0 - distance as f64 / total as f64) + 0.5).floor() as u32
}
#[derive(Clone, Copy, Default)]
struct Chain {
    node: u32,
    prev: u32,
}
#[derive(Clone, Copy, Default, Eq, PartialEq, Hash)]
struct Stack {
    prev: u32,
    left: u32,
    right: u32,
    both: bool,
}
#[derive(Default)]
struct Bucket {
    keys: [u32; 2],
    costs: [Option<u32>; 2],
    len: usize,
}
#[derive(Clone, Copy)]
struct State {
    a: u32,
    b: u32,
    stack: u32,
    cost: u32,
    prev: u32,
    action: u32,
    pct: u32,
    bucket: usize,
    variant: usize,
}
#[derive(Eq, PartialEq)]
struct Entry {
    cost: u32,
    serial: u32,
}
impl Ord for Entry {
    fn cmp(&self, other: &Self) -> Ordering {
        other
            .cost
            .cmp(&self.cost)
            .then(self.serial.cmp(&other.serial))
    }
}
impl PartialOrd for Entry {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}
struct Search<'a> {
    left: &'a [Node],
    right: &'a [Node],
    limit: usize,
    count: usize,
    chains: Vec<Chain>,
    chain_ids: HashMap<(bool, u32, u32), u32>,
    stacks: Vec<Stack>,
    stack_ids: HashMap<Stack, u32>,
    buckets: Vec<Bucket>,
    bucket_ids: HashMap<(i64, i64, bool), usize>,
    similarities: HashMap<(u32, u32), u32>,
    states: Vec<State>,
    heap: BinaryHeap<Entry>,
}
impl<'a> Search<'a> {
    fn new(left: &'a [Node], right: &'a [Node], limit: usize) -> Self {
        Self {
            left,
            right,
            limit,
            count: 0,
            chains: vec![Chain::default()],
            chain_ids: HashMap::new(),
            stacks: vec![Stack::default()],
            stack_ids: HashMap::new(),
            buckets: Vec::new(),
            bucket_ids: HashMap::new(),
            similarities: HashMap::new(),
            states: Vec::new(),
            heap: BinaryHeap::new(),
        }
    }
    fn chain(&mut self, right: bool, node: u32, prev: u32) -> u32 {
        if node == 0 {
            return prev;
        }
        let key = (right, node, prev);
        if let Some(&id) = self.chain_ids.get(&key) {
            return id;
        }
        let id = self.chains.len() as u32;
        self.chains.push(Chain { node, prev });
        self.chain_ids.insert(key, id);
        id
    }
    fn stack(&mut self, value: Stack) -> u32 {
        if let Some(&id) = self.stack_ids.get(&value) {
            return id;
        }
        let id = self.stacks.len() as u32;
        self.stacks.push(value);
        self.stack_ids.insert(value, id);
        id
    }
    fn push(&mut self, parent: u32, a: u32, b: u32, both: bool) -> u32 {
        let frame = self.stacks[parent as usize];
        if !both && parent != 0 && !frame.both {
            let left = self.chain(false, a, frame.left);
            let right = self.chain(true, b, frame.right);
            self.stack(Stack {
                prev: frame.prev,
                left,
                right,
                both: false,
            })
        } else {
            let left = self.chain(false, a, 0);
            let right = self.chain(true, b, 0);
            self.stack(Stack {
                prev: parent,
                left,
                right,
                both,
            })
        }
    }
    fn pop(&mut self, mut a: u32, mut b: u32, mut parent: u32) -> (u32, u32, u32) {
        while parent != 0 {
            let frame = self.stacks[parent as usize];
            if frame.both {
                if a != 0 || b != 0 {
                    break;
                }
                a = self.left[self.chains[frame.left as usize].node as usize].next;
                b = self.right[self.chains[frame.right as usize].node as usize].next;
                parent = frame.prev;
            } else if a == 0 && frame.left != 0 {
                let chain = self.chains[frame.left as usize];
                a = self.left[chain.node as usize].next;
                parent = if chain.prev != 0 || frame.right != 0 {
                    self.stack(Stack {
                        left: chain.prev,
                        ..frame
                    })
                } else {
                    frame.prev
                };
            } else if b == 0 && frame.right != 0 {
                let chain = self.chains[frame.right as usize];
                b = self.right[chain.node as usize].next;
                parent = if frame.left != 0 || chain.prev != 0 {
                    self.stack(Stack {
                        right: chain.prev,
                        ..frame
                    })
                } else {
                    frame.prev
                };
            } else {
                break;
            }
        }
        (a, b, parent)
    }
    // Keep the Lua edge parameter order visible for correspondence auditing.
    #[allow(clippy::too_many_arguments)]
    fn step(&mut self, from: u32, a: u32, b: u32, stack: u32, edge: u32, action: u32, pct: u32) {
        let (a, b, stack) = self.pop(a, b, stack);
        let frame = self.stacks[stack as usize];
        let left_key = if a != 0 {
            a as i64
        } else {
            -(self.chains[frame.left as usize].node as i64)
        };
        let right_key = if b != 0 {
            b as i64
        } else {
            -(self.chains[frame.right as usize].node as i64)
        };
        let key = (left_key, right_key, stack != 0 && !frame.both);
        let index = if let Some(&id) = self.bucket_ids.get(&key) {
            id
        } else {
            let id = self.buckets.len();
            self.buckets.push(Bucket::default());
            self.bucket_ids.insert(key, id);
            id
        };
        let bucket = &mut self.buckets[index];
        let variant = if let Some(i) = (0..bucket.len).find(|&i| bucket.keys[i] == stack) {
            i
        } else {
            if bucket.len == 2 {
                return;
            }
            let i = bucket.len;
            bucket.keys[i] = stack;
            bucket.len += 1;
            i
        };
        let cost = edge
            + if from == NONE {
                0
            } else {
                self.states[from as usize].cost
            };
        if bucket.costs[variant].is_some_and(|old| old <= cost) {
            return;
        }
        if bucket.costs[variant].is_none() {
            self.count += 1;
        }
        bucket.costs[variant] = Some(cost);
        let serial = self.states.len() as u32;
        self.states.push(State {
            a,
            b,
            stack,
            cost,
            prev: from,
            action,
            pct,
            bucket: index,
            variant,
        });
        self.heap.push(Entry { cost, serial });
    }
    fn run(&mut self) -> Option<Vec<[u32; 4]>> {
        self.step(NONE, 1, 1, 0, 0, 0, 0);
        while let Some(entry) = self.heap.pop() {
            if self.count > self.limit {
                return None;
            }
            let v = self.states[entry.serial as usize];
            if self.buckets[v.bucket].costs[v.variant] != Some(v.cost) {
                continue;
            }
            if v.a == 0 && v.b == 0 && v.stack == 0 {
                let mut path = Vec::new();
                let mut current = v;
                while current.prev != NONE {
                    let previous = self.states[current.prev as usize];
                    path.push([current.action, previous.a, previous.b, current.pct]);
                    current = previous;
                }
                path.reverse();
                return Some(path);
            }
            let a = &self.left[v.a as usize];
            let b = &self.right[v.b as usize];
            if v.a != 0 && v.b != 0 {
                let depth = a.depth.abs_diff(b.depth).min(40);
                if a.content == b.content {
                    self.step(
                        entry.serial,
                        a.next,
                        b.next,
                        v.stack,
                        1 + depth + if a.punctuation { 200 } else { 0 },
                        1,
                        0,
                    );
                }
                if a.list && b.list && a.open == b.open && a.close == b.close {
                    let parent = self.push(v.stack, v.a, v.b, true);
                    self.step(entry.serial, a.child, b.child, parent, 10 + depth, 2, 0);
                } else if !a.list && !b.list && a.kind == b.kind && a.kind != 0 && a.text != b.text
                {
                    let pct = *self
                        .similarities
                        .entry((v.a, v.b))
                        .or_insert_with(|| similarity(&a.text, &b.text));
                    self.step(entry.serial, a.next, b.next, v.stack, 600 - pct, 5, pct);
                }
            }
            if v.a != 0 {
                let parent = if a.list {
                    self.push(v.stack, v.a, 0, false)
                } else {
                    v.stack
                };
                self.step(
                    entry.serial,
                    if a.list { a.child } else { a.next },
                    v.b,
                    parent,
                    300,
                    3,
                    0,
                );
            }
            if v.b != 0 {
                let parent = if b.list {
                    self.push(v.stack, 0, v.b, false)
                } else {
                    v.stack
                };
                self.step(
                    entry.serial,
                    v.a,
                    if b.list { b.child } else { b.next },
                    parent,
                    300,
                    4,
                    0,
                );
            }
        }
        None
    }
}
fn solve(input: &[u8]) -> Result<Vec<u8>, String> {
    let mut reader = Reader {
        data: input,
        pos: 0,
    };
    if reader.bytes(4)? != b"GSD1" {
        return Err("unsupported protocol".into());
    }
    let limit = reader.u32()? as usize;
    if limit == 0 || limit > 3_000_000 {
        return Err("invalid graph limit".into());
    }
    let left_count = reader.u32()?;
    let right_count = reader.u32()?;
    let left = reader.nodes(left_count)?;
    let right = reader.nodes(right_count)?;
    if reader.pos != input.len() {
        return Err("trailing request bytes".into());
    }
    let path = Search::new(&left, &right, limit).run();
    let mut output = b"GSR1".to_vec();
    output.extend(u32::from(path.is_none()).to_le_bytes());
    let path = path.unwrap_or_default();
    output.extend((path.len() as u32).to_le_bytes());
    for step in path {
        for value in step {
            output.extend(value.to_le_bytes());
        }
    }
    Ok(output)
}
fn main() {
    let result = (|| {
        let mut input = Vec::new();
        io::stdin()
            .take(MAX_INPUT as u64 + 1)
            .read_to_end(&mut input)
            .map_err(|e| e.to_string())?;
        if input.len() > MAX_INPUT {
            return Err("request too large".into());
        }
        let output = solve(&input)?;
        io::stdout().write_all(&output).map_err(|e| e.to_string())
    })();
    if let Err(error) = result {
        eprintln!("git-syntax-search: {error}");
        std::process::exit(1);
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unicode_and_partial_bytes() {
        assert_eq!(similarity("old😀".as_bytes(), "new😀".as_bytes()), 25);
        assert_eq!(similarity(b"abcd", b"abxcd"), 80);
        assert_eq!(characters(b"\xffa\xc2\x80").len(), 2);
    }
    #[test]
    fn reject_bad_protocol_and_truncation() {
        assert!(solve(b"invalid").is_err());
        assert!(solve(b"GSD1").is_err());
    }
    #[test]
    fn graph_limit_is_not_a_success() {
        let nodes = vec![
            Node::default(),
            Node {
                content: 1,
                ..Node::default()
            },
        ];
        assert!(Search::new(&nodes, &nodes, 1).run().is_none());
        assert_eq!(
            Search::new(&nodes, &nodes, 100).run().unwrap()[0],
            [1, 1, 1, 0]
        );
    }
}
