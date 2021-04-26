# Set the base image
FROM ubuntu:21.04

# Install required packages
RUN apt-get update
RUN DEBIAN_FRONTEND="noninteractive" apt-get -y install --no-install-recommends  tzdata
RUN apt-get install --no-install-recommends -y python3-pip
RUN apt-get -y install --no-install-recommends \
    groff \
    less \
    mailcap \
    mysql-client-8.0 \
    curl \
    bash \
    gnupg \
    coreutils \
    gzip \
    age
RUN apt-get -y install --no-install-recommends git
RUN apt-get install -y --no-install-recommends apt-transport-https ca-certificates gnupg
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
RUN curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key --keyring /usr/share/keyrings/cloud.google.gpg add -
RUN apt-get update
RUN apt-get install -y --no-install-recommends google-cloud-sdk
RUN apt-get clean
RUN apt-get autoremove
RUN pip3 install --upgrade six awscli s3cmd python-magic
    # && \
    #rm /var/cache/apk/*

# Set Default Environment Variables
ENV BACKUP_CREATE_DATABASE_STATEMENT=false
ENV TARGET_DATABASE_PORT=3306
ENV SLACK_ENABLED=false
ENV SLACK_USERNAME=kubernetes-s3-mysql-backup
ENV BACKUP_PROVIDER=aws

RUN gcloud config set core/disable_usage_reporting true && \
    gcloud config set component_manager/disable_update_check true && \
    gcloud config set metrics/environment github_docker_image && \
    gcloud --version

# Copy Slack Alert script and make executable
COPY resources/slack-alert.sh /
RUN chmod +x /slack-alert.sh

# Copy backup script and execute
COPY resources/perform-backup.sh /
RUN chmod +x /perform-backup.sh
CMD ["sh", "/perform-backup.sh"]
