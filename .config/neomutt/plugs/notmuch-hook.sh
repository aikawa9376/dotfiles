#!/bin/sh
notmuch new
# retag all "archive" messages not "new" and "sent" and "notify"
notmuch tag +archive -- not tag:unread and not tag:new and not tag:sent and not tag:notify and not tag:cron and not tag:magazine
# retag all "new" messages "inbox" and "unread"
notmuch tag +inbox +unread -new -- tag:new
# tag all subject in "Cron" as no tag
notmuch tag -inbox +cron -- subject:'Cron'
# tag all messages from "me" as sent and remove tags inbox and unread
notmuch tag -inbox -unread +sent -- from:aikawa@tech-crunch.jp or from:aikawa9376@gmail.com
# tag all messages from "other" as notify and remove tags inbox
notmuch tag -inbox +notify -- not to:aikawa@tech-crunch.jp and not to:aikawa9376@gmail.com and not tag:sent and not tag:cron
notmuch tag -inbox +notify --  from:musicbankaudition@gmail.com or from:wordpress
# tag all subject in "メルマガ" as no tag
notmuch tag +magazine -- \
  'メルマガ' or 'メールマガジン' or '配信停止' or '購読' \
  '配信の解除' or '送信専用' or 'no-reply' or '発行者' or '配信解除'
notmuch tag +magazine -- 'from:"/noreply.*@.*/"' and not tag:notify
# tag all messages from "archive" as not unread
notmuch tag -inbox -unread -- tag:archive or tag:notify or tag:magazine

