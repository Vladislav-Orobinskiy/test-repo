#!/bin/bash
# Скрипт для автоматической загрузки данных из maillog

echo "Waiting for PostgreSQL to be ready..."
until pg_isready -h postgres -U postgres -d testdb; do
  sleep 1
done

echo "PostgreSQL is ready. Checking if data already exists..."

# Проверяем, есть ли уже данные
DATA_COUNT=$(psql -h postgres -U postgres -d testdb -t -c "select count(*) from message;" 2>/dev/null | tr -d ' ')

if [ "$DATA_COUNT" = "0" ]; then
    echo "No data found. Loading maillog..."

    # Ищем файл maillog или "out 2"
    if [ -f "/app/maillog" ]; then
        perl /app/parse_maillog.pl /app/maillog
    elif [ -f "/app/out 2" ]; then
        perl /app/parse_maillog.pl "/app/out 2"
    else
        echo "Warning: No maillog file found. Please place maillog or 'out 2' file in the project directory."
    fi
else
    echo "Data already exists ($DATA_COUNT messages). Skipping load."
fi
