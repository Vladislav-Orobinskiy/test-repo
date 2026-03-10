#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use DBI;
use Time::Piece;

# Настройки подключения к БД
my $db_config = {
	host => $ENV{POSTGRES_HOST}     || 'localhost',
	port => $ENV{POSTGRES_PORT}     || '5432',
	name => $ENV{POSTGRES_DB}       || 'testdb',
	user => $ENV{POSTGRES_USER}     || 'postgres',
	pass => $ENV{POSTGRES_PASSWORD} || 'postgres',
};

# Подключение к БД
my $dsn = sprintf(
    "DBI:Pg:dbname=%s;host=%s;port=%s",
    $db_config->{name},
    $db_config->{host},
    $db_config->{port}
);
my $dbh = DBI->connect($dsn, $db_config->{user}, $db_config->{pass}, {
	RaiseError     => 1,
	AutoCommit     => 0,
	pg_enable_utf8 => 1,
}) or die "Cannot connect to database: $DBI::errstr\n";

# Подготовка SQL запросов
my $insert_message = $dbh->prepare(
	"insert into message (created, id, int_id, str) values (?, ?, ?, ?)"
);

my $insert_log = $dbh->prepare(
	"insert into log (created, int_id, str, address) values (?, ?, ?, ?)"
);

# Имя файла лога
my $logfile = shift @ARGV || 'maillog';
unless (-f $logfile) {
	die "File not found: $logfile\n";
}

print "Parsing $logfile...\n";

open(my $fh, '<:utf8', $logfile) or die "Cannot open $logfile: $!\n";

my $counters = {
	line    => 0,
	message => 0,
	log     => 0,
};

while (my $line = <$fh>) {
	chomp $line;
	$counters->{line}++;

	# Пропускаем пустые строки
	next if $line =~ /^\s*$/;

	# Парсим строку лога
	my ($timestamp, $rest) = _parse_line($line);
	next unless $timestamp;

	# Ищем внутренний ID сообщения (формат: int_id или int_id:)
	# В новом формате int_id идет сразу после timestamp
	if ($rest =~ /^([A-Za-z0-9\-]+)\s+(.+)$/) {
		my $int_id = $1;
		my $after_id = $2;

		# Проверяем флаг
		if ($after_id =~ /^<=\s+(.+)$/) {
			# Прибытие сообщения (<=) - записываем в message
			_process_message(
				$insert_message,
				$counters,
				$timestamp,
				$int_id, $rest
			);
		} elsif ($after_id =~ /^(=>|->|\*\*|==)\s+(.+)$/) {
			# Остальные флаги (=>, ->, **, ==) - записываем в log
			my $after_flag = $2;
			my $address = _extract_address($after_flag);
			_process_log_with_flag(
				$insert_log,
				$counters,
				$timestamp,
				$int_id,
				$rest,
				$address
			);
		} else {
			# Нет флага - общая информация, записываем в log без адреса
			_process_log_without_flag(
				$insert_log,
				$counters,
				$timestamp,
				$int_id,
				$rest
			);
		}
	} else {
		# Нет int_id - общая информация
		_process_log_without_int_id(
			$insert_log,
			$counters,
			$timestamp,
			$rest
		);
	}

	# Коммитим каждые 1000 строк для производительности
	if ($counters->{line} % 1000 == 0) {
		$dbh->commit;
		print "Processed $counters->{line} lines...\n";
	}
}

# Финальный коммит
$dbh->commit;

close($fh);

print "\nDone!\n";
print "Total lines processed: $counters->{line}\n";
print "Messages inserted: $counters->{message}\n";
print "Log entries inserted: $counters->{log}\n";

$dbh->disconnect;

# Парсинг строки лога: извлечение timestamp и остальной части
sub _parse_line {
	my ($line) = @_;

	# Парсим дату и время (формат YYYY-MM-DD HH:MM:SS или старый формат)
	my $timestamp_str;
	my $rest;

	if ($line =~ /^(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\s+(.+)$/) {
		# Новый формат: YYYY-MM-DD HH:MM:SS
		$timestamp_str = $1;
		$rest = $2;
		$timestamp_str =~ s/^(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2})$/$1 $2/;
	} elsif ($line =~ /^(\w+\s+\d+\s+\d+:\d+:\d+)\s+(.+)$/) {
		# Старый формат: Jan 1 12:00:00
		$timestamp_str = $1;
		$rest = $2;
	} else {
		return (undef, undef);
	}

	# Парсим timestamp
	my $timestamp = parse_timestamp($timestamp_str);
	unless ($timestamp) {
		warn "Cannot parse timestamp: $timestamp_str\n";
		return (undef, undef);
	}

	return ($timestamp, $rest);
}

# Обработка сообщения с флагом <=
sub _process_message {
	my ($insert_message, $counters, $timestamp, $int_id, $str) = @_;

	# Ищем id=xxxx в строке
	my $id = '';
	if ($str =~ /id=([^\s]+)/) {
		$id = $1;
	} else {
		# Если id не найден, используем int_id
		$id = $int_id;
	}

	# Обрезаем int_id до 16 символов
	$int_id = _truncate_int_id($int_id);

	eval {
		$insert_message->execute(
			$timestamp,
			$id,
			$int_id,
			$str
		);
		$counters->{message}++;
	};
	if ($@) {
		warn "Error inserting message: $@\n";
	}
}

# Извлечение адреса из строки
sub _extract_address {
	my ($after_flag) = @_;

	# Извлекаем адрес: может быть в угловых скобках <email@domain.com> или просто email@domain.com
	my $address = '';
	if ($after_flag =~ /<([^>]+)>/) {
		$address = $1;
	} elsif ($after_flag =~ /^(\S+@\S+)/) {
		$address = $1;
	} elsif ($after_flag =~ /^(\S+)/) {
		# Берем первое слово, если это не email
		$address = $1;
		# Если это не похоже на email, очищаем
		$address = '' unless $address =~ /@/;
	}

	return $address;
}

# Обработка лога с флагами (=>, ->, **, ==)
sub _process_log_with_flag {
	my ($insert_log, $counters, $timestamp, $int_id, $str, $address) = @_;

	# Обрезаем int_id до 16 символов
	$int_id = _truncate_int_id($int_id);

	_insert_log_entry(
		$insert_log,
		$counters,
		$timestamp,
		$int_id,
		$str,
		$address
	);
}

# Обработка лога без флага
sub _process_log_without_flag {
	my ($insert_log, $counters, $timestamp, $int_id, $str) = @_;

	# Обрезаем int_id до 16 символов
	$int_id = _truncate_int_id($int_id);

	_insert_log_entry(
		$insert_log,
		$counters,
		$timestamp,
		$int_id,
		$str,
		undef
	);
}

# Обработка строки без int_id
sub _process_log_without_int_id {
	my ($insert_log, $counters, $timestamp, $str) = @_;

	my $int_id = ''; # Пустой int_id для общих записей

	_insert_log_entry(
		$insert_log,
		$counters,
		$timestamp,
		$int_id,
		$str,
		undef
	);
}

# Вставка записи в таблицу log
sub _insert_log_entry {
	my ($insert_log, $counters, $timestamp, $int_id, $str, $address) = @_;

	eval {
		$insert_log->execute(
			$timestamp,
			$int_id,
			$str,
			$address
		);
		$counters->{log}++;
	};
	if ($@) {
		warn "Error inserting log: $@\n";
	}
}

# Обрезание int_id до 16 символов
sub _truncate_int_id {
	my ($int_id) = @_;
	return substr($int_id, 0, 16);
}

# Функция парсинга timestamp
sub parse_timestamp {
	my ($ts_str) = @_;

	# Формат 1: "2012-02-13 14:39:22" (YYYY-MM-DD HH:MM:SS)
	if ($ts_str =~ /^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})$/) {
		return "$1-$2-$3 $4:$5:$6";
	}

	# Формат 2: "Jan  1 12:00:00" или "Jan 1 12:00:00"
	# Нужно добавить год (текущий)
	if ($ts_str =~ /^(\w+)\s+(\d+)\s+(\d+):(\d+):(\d+)$/) {
		my ($month_name, $day, $hour, $min, $sec) = ($1, $2, $3, $4, $5);

		# Конвертируем название месяца в число
		my %months = (
			'Jan' => 1, 'Feb' => 2, 'Mar' => 3, 'Apr' => 4,
			'May' => 5, 'Jun' => 6, 'Jul' => 7, 'Aug' => 8,
			'Sep' => 9, 'Oct' => 10, 'Nov' => 11, 'Dec' => 12
		);

		my $month = $months{$month_name} || 1;
		my $current_year = localtime->year;

		# Создаем Time::Piece объект
		my $tp = Time::Piece->new();
		$tp = $tp->set_year($current_year);
		$tp = $tp->set_mon($month);
		$tp = $tp->set_mday($day);
		$tp = $tp->set_hour($hour);
		$tp = $tp->set_minute($min);
		$tp = $tp->set_second($sec);

		return $tp->strftime('%Y-%m-%d %H:%M:%S');
	}

	return undef;
}
