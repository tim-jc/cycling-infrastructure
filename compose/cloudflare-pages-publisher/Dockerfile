FROM node:22.18.0-bookworm-slim

ARG WRANGLER_VERSION=4.33.1

RUN npm install --global --omit=dev "wrangler@${WRANGLER_VERSION}" \
    && test "$(wrangler --version | awk '{print $1}')" = "${WRANGLER_VERSION}"

ENV HOME=/tmp/wrangler-home

RUN mkdir -p "$HOME" && chmod 1777 "$HOME"

ENTRYPOINT ["wrangler"]
CMD ["pages", "deploy", "/site", "--project-name", "cycling-analytics"]
