FROM docker.io/alpine:latest

RUN apk add --no-cache openssh-client \
    && adduser -D -u 1000 -s /bin/sh explorer

# Switch to explorer so the .ssh directory is owned by UID 1000 from the start
USER explorer
RUN mkdir -p /home/explorer/.ssh && chmod 700 /home/explorer/.ssh

WORKDIR /home/explorer
