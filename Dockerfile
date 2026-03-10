FROM perl:5.36-slim

WORKDIR /app

# Установка зависимостей для работы с PostgreSQL
RUN apt-get update && apt-get install -y \
    libpq-dev \
    postgresql-client \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Установка Perl модулей
RUN cpanm --notest DBI DBD::Pg Plack

# Копируем файлы
COPY . /app

# Делаем скрипты исполняемыми
RUN chmod +x /app/*.pl

EXPOSE 8080
