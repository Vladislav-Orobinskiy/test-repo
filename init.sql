-- Инициализация базы данных
-- Схема для работы с почтовыми логами

create table if not exists message (
    created timestamp(0) without time zone not null,
    id varchar not null,
    int_id char(16) not null,
    str varchar not null,
    status bool,
    constraint message_id_pk primary key(id)
);

create index if not exists message_created_idx on message (created);
create index if not exists message_int_id_idx on message (int_id);

create table if not exists log (
    created timestamp(0) without time zone not null,
    int_id char(16) not null,
    str varchar,
    address varchar
);

create index if not exists log_address_idx on log using hash (address);
