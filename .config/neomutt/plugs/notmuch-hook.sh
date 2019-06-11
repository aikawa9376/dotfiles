#!/bin/sh
notmuch new
# retag all "archive" messages not "new" and "sent" and "notify"
notmuch tag +archive -- not tag:new and not tag:sent and not tag:notify and not tag:cron
# retag all "new" messages "inbox" and "unread"
notmuch tag +inbox +unread -new -- tag:new
# tag all subject in "Cron" as no tag
notmuch tag -inbox +cron -- subject:'Cron'
# tag all messages from "me" as sent and remove tags inbox and unread
notmuch tag -inbox -unread +sent -- from:aikawa@tech-crunch.jp or from:aikawa9376@gmail.com
# tag all messages from "other" as notify and remove tags inbox
notmuch tag -inbox +notify -- not to:aikawa@tech-crunch.jp and not to:aikawa9376@gmail.com and not tag:sent and not tag:cron

