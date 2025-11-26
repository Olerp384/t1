FROM alpine:3.19

# bash нужен, потому что скрипт написан под bash
# git — для clone, ca-certificates — для https
RUN apk add --no-cache \
    bash \
    git \
    ca-certificates

WORKDIR /app

COPY selfdeploy.sh /app/selfdeploy.sh
RUN chmod +x /app/selfdeploy.sh

ENTRYPOINT ["/app/selfdeploy.sh"]

