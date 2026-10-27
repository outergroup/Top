FROM alpine:3.22 AS build
RUN apk add --no-cache build-base
WORKDIR /src
COPY . .
RUN cc -std=gnu17 -Os -static -Wall -Wextra -Werror -Wno-unused-function *.c -lpthread -lm -o /outer-top-helper && strip /outer-top-helper
FROM scratch
COPY --from=build /outer-top-helper /outer-top-helper
