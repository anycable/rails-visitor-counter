# syntax = docker/dockerfile:experimental

# Dockerfile used to build a deployable image for a Rails application.
# Adjust as required.
#
# Common adjustments you may need to make over time:
#  * Modify version numbers for Ruby, Bundler, and other products.
#  * Add library packages needed at build time for your gems, node modules.
#  * Add deployment packages needed by your application
#  * Add (often fake) secrets needed to compile your assets

#######################################################################

# Learn more about the chosen Ruby stack, Fullstaq Ruby, here:
#   https://github.com/evilmartians/fullstaq-ruby-docker.
#
# We recommend using the highest patch level for better security and
# performance.

ARG RUBY_VERSION=3.1.2
ARG VARIANT=jemalloc-slim
FROM quay.io/evl.ms/fullstaq-ruby:${RUBY_VERSION}-${VARIANT} as base

LABEL fly_launch_runtime="rails"

ARG BUNDLER_VERSION=2.3.23

ARG RAILS_ENV=production
ENV RAILS_ENV=${RAILS_ENV}
ENV RAILS_LOG_TO_STDOUT true

ARG BUNDLE_WITHOUT=development:test
ARG BUNDLE_PATH=vendor/bundle
ENV BUNDLE_PATH ${BUNDLE_PATH}
ENV BUNDLE_WITHOUT ${BUNDLE_WITHOUT}

RUN mkdir /app
WORKDIR /app
RUN mkdir -p tmp/pids

#######################################################################

# install packages only needed at build time

FROM base as build_deps

ARG BUILD_PACKAGES="git build-essential wget vim curl gzip xz-utils libsqlite3-dev"
ENV BUILD_PACKAGES ${BUILD_PACKAGES}

RUN --mount=type=cache,id=dev-apt-cache,sharing=locked,target=/var/cache/apt \
    --mount=type=cache,id=dev-apt-lib,sharing=locked,target=/var/lib/apt \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y ${BUILD_PACKAGES} \
    && rm -rf /var/lib/apt/lists /var/cache/apt/archives

#######################################################################

# install gems

FROM build_deps as gems

RUN gem update --system --no-document && \
    gem install -N bundler -v ${BUNDLER_VERSION}

COPY Gemfile* ./
RUN bundle install &&  rm -rf vendor/bundle/ruby/*/cache

#######################################################################

# install anycable
FROM golang:1.18 as go
RUN GOBIN=/usr/local/bin/ go install github.com/anycable/anycable-go/cmd/anycable-go@latest

#######################################################################

# install deployment packages

FROM base

# add passenger repository
RUN apt-get install -y dirmngr gnupg apt-transport-https ca-certificates curl && \
  curl https://oss-binaries.phusionpassenger.com/auto-software-signing-gpg-key.txt | \
    gpg --dearmor > /etc/apt/trusted.gpg.d/phusion.gpg && \
  sh -c 'echo deb https://oss-binaries.phusionpassenger.com/apt/passenger bullseye main > /etc/apt/sources.list.d/passenger.list'

ARG DEPLOY_PACKAGES="file vim curl gzip nginx passenger libnginx-mod-http-passenger libsqlite3-0 ruby-foreman redis-server avahi-daemon avahi-utils libnss-mdns"
ENV DEPLOY_PACKAGES=${DEPLOY_PACKAGES}

RUN --mount=type=cache,id=prod-apt-cache,sharing=locked,target=/var/cache/apt \
    --mount=type=cache,id=prod-apt-lib,sharing=locked,target=/var/lib/apt \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y \
    ${DEPLOY_PACKAGES} \
    && rm -rf /var/lib/apt/lists /var/cache/apt/archives

# configure redis
RUN sed -i 's/^daemonize yes/daemonize no/' /etc/redis/redis.conf &&\
  sed -i 's/^bind/# bind/' /etc/redis/redis.conf &&\
  sed -i 's/^protected-mode yes/protected-mode no/' /etc/redis/redis.conf &&\
  sed -i 's/^logfile/# logfile/' /etc/redis/redis.conf 

# copy installed gems
COPY --from=gems /app /app
COPY --from=gems /usr/lib/fullstaq-ruby/versions /usr/lib/fullstaq-ruby/versions
COPY --from=gems /usr/local/bundle /usr/local/bundle

# copy anycable-go
COPY --from=go /usr/local/bin/anycable-go /usr/local/bin/anycable-go

#######################################################################

# configure avahi for ipv6
RUN sed -i 's/mdns4_minimal/mdns_minimal/' /etc/nsswitch.conf

# configure nginx/passenger
COPY config/nginx.conf /etc/nginx/sites-available/rails.conf
RUN rm /etc/nginx/sites-enabled/default && \
    ln -s /etc/nginx/sites-available/rails.conf /etc/nginx/sites-enabled/ && \
    sed -i 's/user .*;/user root;/' /etc/nginx/nginx.conf && \
    sed -i '/^include/i include /etc/nginx/main.d/*.conf;' /etc/nginx/nginx.conf && \
    mkdir /etc/nginx/main.d && \
    echo 'env RAILS_MASTER_KEY;' >> /etc/nginx/main.d/env.conf &&\
    echo 'env REDIS_URL;' >> /etc/nginx/main.d/env.conf &&\
    echo 'env ANYCABLE_RPC_HOST;' >> /etc/nginx/main.d/env.conf &&\
    echo 'env CABLE_URL;' >> /etc/nginx/main.d/env.conf &&\
    echo 'env RAILS_LOG_TO_STDOUT;' >> /etc/nginx/main.d/env.conf

# Deploy your application
COPY . .

# Adjust binstubs to run on Linux and set current working directory
RUN chmod +x /app/bin/* && \
    sed -i 's/ruby.exe/ruby/' /app/bin/* && \
    sed -i '/^#!/aDir.chdir File.expand_path("..", __dir__)' /app/bin/*

# The following enable assets to precompile on the build server.  Adjust
# as necessary.  If no combination works for you, see:
# https://fly.io/docs/rails/getting-started/existing/#access-to-environment-variables-at-build-time
ENV SECRET_KEY_BASE 1
# ENV AWS_ACCESS_KEY_ID=1
# ENV AWS_SECRET_ACCESS_KEY=1

# Run build task defined in lib/tasks/fly.rake
ARG BUILD_COMMAND="bin/rails fly:build"
RUN ${BUILD_COMMAND}

# Default server start instructions.  Generally Overridden by fly.toml.
ENV PORT 8080
ARG SERVER_COMMAND="bin/rails fly:server"
ENV SERVER_COMMAND ${SERVER_COMMAND}
CMD ${SERVER_COMMAND}
