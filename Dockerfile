# ---------- Stage 1: Composer dependencies ----------
FROM composer:2 AS vendor

WORKDIR /app

COPY database/ database/
COPY composer.json composer.lock ./

RUN composer install \
    --no-dev \
    --no-scripts \
    --no-autoloader \
    --ignore-platform-reqs \
    --prefer-dist

COPY . .

RUN composer dump-autoload --optimize --no-dev \
    && composer run-script post-autoload-dump || true

# ---------- Stage 2: PHP-FPM runtime ----------
FROM php:8.2-fpm-alpine AS app

RUN apk add --no-cache \
        bash \
        curl \
        libzip-dev \
        libpng-dev \
        libjpeg-turbo-dev \
        freetype-dev \
        icu-dev \
        oniguruma-dev \
        postgresql-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        pdo_mysql \
        pdo_pgsql \
        gd \
        zip \
        intl \
        bcmath \
        opcache \
    && apk del --no-cache libpng-dev libjpeg-turbo-dev freetype-dev icu-dev oniguruma-dev postgresql-dev

WORKDIR /var/www/html

COPY --from=vendor /app /var/www/html
COPY docker/php/local.ini /usr/local/etc/php/conf.d/local.ini

RUN addgroup -g 1000 www && adduser -G www -g www -s /bin/sh -D www \
    && chown -R www:www /var/www/html \
    && chmod -R 775 storage bootstrap/cache

USER www

EXPOSE 9000
CMD ["php-fpm"]
