# Cube service image. Railway cannot bind-mount files, so this bakes Formbricks'
# Cube configuration and FeedbackRecords model (docker/cube in formbricks/formbricks
# at tag 6.2.1, AGPL-3.0) onto Formbricks' own distroless Cube image. Nothing else
# changes: the image has no shell, runs as UID 65532 and starts Cube's server.
FROM ghcr.io/formbricks/cube:1.8.8-3@sha256:dbe4b87e37e54e634e8cb3e8b6fd1d5cb9e2d84fe6225abbec9cb715c71fe50e

COPY cube/cube.js /cube/conf/cube.js
COPY cube/model/ /cube/conf/model/
