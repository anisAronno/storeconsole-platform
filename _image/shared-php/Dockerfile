FROM php:8.4-fpm-alpine

RUN apk add --no-cache \
    git \
    curl \
    bash \
    zip \
    unzip \
    libzip-dev \
    libpng-dev \
    libjpeg-turbo-dev \
    freetype-dev \
    libxml2-dev \
    icu-dev \
    oniguruma-dev \
    autoconf \
    gcc \
    g++ \
    make \
    linux-headers \
    postgresql-dev \
    supervisor \
    htpasswd

RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
 && docker-php-ext-install \
    pdo_pgsql \
    pgsql \
    mbstring \
    exif \
    pcntl \
    bcmath \
    gd \
    zip \
    intl \
    opcache

RUN pecl install redis && docker-php-ext-enable redis

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

RUN mkdir -p /run/shared-php-fpm /var/log/php-fpm \
 && chown www-data:www-data /run/shared-php-fpm /var/log/php-fpm

COPY php-fpm.conf /usr/local/etc/php-fpm.conf
COPY pools/ /usr/local/etc/php-fpm.d/

CMD ["php-fpm", "-F"]
