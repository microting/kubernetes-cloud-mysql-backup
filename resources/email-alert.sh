#!/bin/sh

SUBJECT="$1"
BODY="$2"

curl -s --url "smtp://${EMAIL_SMTP_HOST}:${EMAIL_SMTP_PORT}" \
  --ssl-reqd \
  --mail-from "$EMAIL_FROM" \
  --mail-rcpt "$EMAIL_TO" \
  --user "${EMAIL_SMTP_USER}:${EMAIL_SMTP_PASSWORD}" \
  -T - <<EOF
From: ${EMAIL_FROM}
To: ${EMAIL_TO}
Subject: ${SUBJECT}

${BODY}
EOF
