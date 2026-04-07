#!/bin/sh

SUBJECT="$1"
BODY="$2"

# Configure msmtp
cat > /tmp/msmtprc <<EOF
account default
host ${EMAIL_SMTP_HOST}
port ${EMAIL_SMTP_PORT}
auth on
user ${EMAIL_SMTP_USER}
password ${EMAIL_SMTP_PASSWORD}
from ${EMAIL_FROM}
tls on
tls_starttls on
tls_certcheck off
EOF

# Send email
printf "To: %s\nFrom: %s\nSubject: %s\n\n%s\n" \
  "$EMAIL_TO" "$EMAIL_FROM" "$SUBJECT" "$BODY" \
  | msmtp --file=/tmp/msmtprc "$EMAIL_TO"

rm -f /tmp/msmtprc
