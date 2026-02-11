FROM ruby:3.2-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential libxml2-dev libxslt1-dev zlib1g-dev curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy dependency files FIRST (cached until Gemfile changes)
COPY Gemfile Gemfile.lock ./

# Dung system libraries cho Nokogiri (90s -> 11s build time)
ENV NOKOGIRI_USE_SYSTEM_LIBRARIES=true

RUN bundle config set --local without 'development test' && \
    bundle install --jobs 4 && \
    rm -rf /usr/local/bundle/cache

# Copy app code LAST (rebuilds only khi code thay doi)
COPY . .

EXPOSE 4567
CMD ["ruby", "app.rb"]
