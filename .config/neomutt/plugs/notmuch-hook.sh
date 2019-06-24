#!/bin/sh
notmuch new
# retag all "archive" messages not "new" and "sent" and "notify"
notmuch tag +spam -new -unread -- tag:new and 'folder:[Gmail].迷惑メール]'
notmuch tag +archive -- tag:new
# tag all subject in "Cron" as no tag
notmuch tag -archive +cron -- tag:new and subject:'Cron'
# tag all messages from "me" as sent and remove tags inbox and unread
notmuch tag -archive +sent -- tag:new and from:aikawa@tech-crunch.jp or from:aikawa9376@gmail.com
# tag all messages from "other" as notify and remove tags inbox
notmuch tag -archive +notify -- tag:new and not tag:sent and not tag:cron and not to:aikawa@tech-crunch.jp and not to:aikawa9376@gmail.com
notmuch tag -archive +notify -- tag:new and from:musicbankaudition@gmail.com or from:wordpress or 'from:"/.*@fullgorilla.*co.jp/"'
notmuch tag -archive +notify -- tag:new and not tag:notify and not admin@onamae.com and 'from:"/.*@.*onamae.*com/"'
# tag all subject in "メルマガ" as no tag
notmuch tag -archive +magazine -- tag:new and \
  'メルマガ' or 'メールマガジン' or '配信停止' or '購読' \
  '配信の解除' or '送信専用' or 'no-reply' or '発行者' or '配信解除'
notmuch tag -archive +magazine -- tag:new and not tag:notify  \
  and 'from:"/noreply.*@.*/"' or 'from:"/news.*@.*/"' or 'from:"/.*@.*ferret.*com/"' or 'from:"/.*@.*facebook.*com/"' \
  or 'from:"/.*@.*nojima.*co.jp/"' or 'from:"/.*@nature.*global/"'
# tag set finish
notmuch tag -new -- tag:new

