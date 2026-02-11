# Multi-stage build — loai bo ~80MB Composer tooling khoi final image
FROM composer:latest AS deps
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-dev --optimize-autoloader --no-interaction

FROM php:8.1-cli
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=deps /app/vendor ./vendor
COPY . .
EXPOSE 8080
CMD ["php", "-S", "0.0.0.0:8080", "index.php"]
