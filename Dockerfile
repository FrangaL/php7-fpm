FROM debian:buster-slim

RUN set -eux; \
  { \
  echo 'Package: php*'; \
  echo 'Pin: release *'; \
  echo 'Pin-Priority: -1'; \
  } > /etc/apt/preferences.d/no-debian-php

ENV PHPIZE_DEPS \
  autoconf \
  dpkg-dev \
  file \
  g++ \
  gcc \
  libc-dev \
  make \
  pkg-config \
  re2c

RUN apt-get update && apt-get install -y \
  $PHPIZE_DEPS \
  ca-certificates \
  curl \
  xz-utils \
  --no-install-recommends && rm -r /var/lib/apt/lists/*

ENV PHP_INI_DIR /usr/local/etc/php
RUN mkdir -p $PHP_INI_DIR/conf.d

ENV PHP_EXTRA_CONFIGURE_ARGS --enable-fpm --with-fpm-user=www-data --with-fpm-group=www-data

ENV PHP_CFLAGS="-fstack-protector-strong -fpic -fpie -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64"
ENV PHP_CPPFLAGS="$PHP_CFLAGS"
ENV PHP_LDFLAGS="-Wl,-O1 -Wl,--hash-style=both -pie"

ENV DEBIAN_FRONTEND=noninteractive

RUN set -xe; \
  \
  fetchDeps=' \
  git \
  '; \
  if ! command -v gpg > /dev/null; then \
  fetchDeps="$fetchDeps \
  dirmngr \
  gnupg \
  "; \
  fi; \
  apt-get update; \
  apt-get install -y --no-install-recommends $fetchDeps; \
  rm -rf /var/lib/apt/lists/*; \
  mkdir -p /usr/src; \
  cd /usr/src; \
  git clone --single-branch --branch PHP-7.4 https://github.com/php/php-src.git php; \
  cd php; \
  ./buildconf --force; \
  rm -rf .git; \
  cd /usr/src; \
  tar -cJf php.tar.xz php; \
  rm -rf php; \
  apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false $fetchDeps

COPY data/docker-php-source /usr/local/bin/

RUN set -eux; \
  \
  savedAptMark="$(apt-mark showmanual)"; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
  bison \
  libcurl4-openssl-dev \
  libedit-dev \
  libonig-dev \
  libsodium-dev \
  libsqlite3-dev \
  libssl-dev \
  libxml2-dev \
  zlib1g-dev \
  libzip-dev \
  libfreetype6-dev \
  libjpeg62-turbo-dev \
  libpng-dev \
  libargon2-dev \
  ${PHP_EXTRA_BUILD_DEPS:-} \
  ; \
  rm -rf /var/lib/apt/lists/*; \
  export \
  CFLAGS="$PHP_CFLAGS" \
  CPPFLAGS="$PHP_CPPFLAGS" \
  LDFLAGS="$PHP_LDFLAGS" \
  ; \
  docker-php-source extract; \
  cd /usr/src/php; \
  gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
  debMultiarch="$(dpkg-architecture --query DEB_BUILD_MULTIARCH)"; \
  if [ ! -d /usr/include/curl ]; then \
  ln -sT "/usr/include/$debMultiarch/curl" /usr/local/include/curl; \
  fi; \
  ./configure \
  --build="$gnuArch" \
  --with-config-file-path="$PHP_INI_DIR" \
  --with-config-file-scan-dir="$PHP_INI_DIR/conf.d" \
  --enable-option-checking=fatal \
  --disable-cgi \
  --with-mhash \
  --enable-ftp \
  --enable-mbstring \
  --enable-mysqlnd \
  --with-password-argon2 \
  --with-sodium \
  --with-curl \
  --with-libedit \
  --with-zip \
  --with-openssl \
  --with-zlib \
  --with-pear \
  --with-freetype \
  --with-jpeg \
  --enable-gd \
  $(test "$gnuArch" = 's390x-linux-gnu' && echo '--without-pcre-jit') \
  --with-libdir="lib/$debMultiarch" \
  ${PHP_EXTRA_CONFIGURE_ARGS:-} \
  ; \
  make -j "$(nproc)"; \
  curl https://raw.githubusercontent.com/pear/pearweb_phars/master/install-pear-nozlib.phar > pear/install-pear-nozlib.phar; \
  make install; \
  find /usr/local/bin /usr/local/sbin -type f -executable -exec strip --strip-all '{}' + || true; \
  make clean; \
  cd /; \
  docker-php-source delete;

COPY data/docker-php-* /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-php-*

RUN php --version; \
  pecl update-channels; \
  pecl install redis \
  && docker-php-ext-enable redis \
  && rm -rf /tmp/pear ~/.pearrc

RUN	apt-mark auto '.*' > /dev/null; \
  [ -z "$savedAptMark" ] || apt-mark manual $savedAptMark; \
  find /usr/local -type f -executable -exec ldd '{}' ';' \
  | awk '/=>/ { print $(NF-1) }' \
  | sort -u \
  | xargs -r dpkg-query --search \
  | cut -d: -f1 \
  | sort -u \
  | xargs -r apt-mark manual \
  ; \
  apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false bison;

ENTRYPOINT ["docker-php-entrypoint"]

WORKDIR /var/www

RUN set -ex \
  && cd /usr/local/etc \
  && if [ -d php-fpm.d ]; then \
  # for some reason, upstream's php-fpm.conf.default has "include=NONE/etc/php-fpm.d/*.conf"
  sed 's!=NONE/!=!g' php-fpm.conf.default | tee php-fpm.conf > /dev/null; \
  mv php-fpm.d/www.conf.default php-fpm.d/www.conf; \
  else \
  mkdir php-fpm.d; \
  mv php-fpm.conf.default php-fpm.d/www.conf; \
  { \
  echo '[global]'; \
  echo 'include=etc/php-fpm.d/*.conf'; \
  } | tee php-fpm.conf; \
  fi \
  && { \
  echo '[global]'; \
  echo 'error_log = /proc/self/fd/2'; \
  echo; \
  echo '[www]'; \
  echo '; if we send this to /proc/self/fd/1, it never appears'; \
  echo 'access.log = /proc/self/fd/2'; \
  echo; \
  echo 'clear_env = no'; \
  echo; \
  echo '; Ensure worker stdout and stderr are sent to the main error log.'; \
  echo 'catch_workers_output = yes'; \
  } | tee php-fpm.d/docker.conf \
  && { \
  echo '[global]'; \
  echo 'daemonize = no'; \
  echo; \
  echo '[www]'; \
  echo 'listen = 8000'; \
  } | tee php-fpm.d/zz-docker.conf \
  && echo 'expose_php = off' >> $PHP_INI_DIR/conf.d/php_ver.ini

RUN set -x \
  && php -v | grep -oE 'PHP\s[.0-9]+' | grep -oE '[.0-9]+' | grep '^7.4' \
  && /usr/local/sbin/php-fpm --test \
  && PHP_ERROR="$( php -v 2>&1 1>/dev/null )" \
  && if [ -n "${PHP_ERROR}" ]; then echo "${PHP_ERROR}"; false; fi

RUN apt-get update && apt-get install -y --no-install-recommends -o APT::Install-Suggests=0 \
  curl ca-certificates git nano

RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

RUN curl -sL https://deb.nodesource.com/setup_12.x | bash - \
        && apt install -y --no-install-recommends -o APT::Install-Suggests=0 nodejs \
        && rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin \
        && apt-get clean

ENV DEBIAN_FRONTEND=newt

CMD ["php-fpm"]

# Build-time metadata as defined at http://label-schema.org
ARG BUILD_DATE
ARG VCS_REF
ARG VCS_URL

LABEL maintainer="FrangaL <frangal@gmail.com>" \
  org.label-schema.build-date="$BUILD_DATE" \
  org.label-schema.version="7.4" \
  org.label-schema.docker.schema-version="1.0" \
  org.label-schema.name="php7-fpm" \
  org.label-schema.description="This is a PHP7 Debian Docker image" \
  org.label-schema.vcs-ref=$VCS_REF \
  org.label-schema.vcs-url=$VCS_URL
