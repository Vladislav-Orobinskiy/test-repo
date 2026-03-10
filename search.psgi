#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use DBI;
use Plack::Request;
use Encode;
use File::Spec;

sub _escape_html {
    my $str = shift || '';
    $str =~ s/&/&amp;/g;
    $str =~ s/</&lt;/g;
    $str =~ s/>/&gt;/g;
    $str =~ s/"/&quot;/g;
    $str =~ s/'/&#39;/g;
    return $str;
}

sub _load_template {
    # Пробуем разные пути: в контейнере /app, локально - текущая директория
    my @possible_paths = (
        File::Spec->catfile('/app', 'tmpl', 'search.html'),
        File::Spec->catfile(File::Spec->curdir(), 'tmpl', 'search.html'),
    );

    my $template_file;
    for my $path (@possible_paths) {
        if (-f $path) {
            $template_file = $path;
            last;
        }
    }

    die "Cannot find template file (searched: @possible_paths)\n" unless $template_file;

    open(my $fh, '<:utf8', $template_file) or die "Cannot open template $template_file: $!\n";
    local $/;

    my $content = <$fh>;
    close($fh);

    return $content;
}

sub {
    my $env = shift;
    my $req = Plack::Request->new($env);

    # Настройки подключения к БД
    my $db_config = {
        host => $ENV{POSTGRES_HOST} || 'localhost',
        port => $ENV{POSTGRES_PORT} || '5432',
        name => $ENV{POSTGRES_DB} || 'testdb',
        user => $ENV{POSTGRES_USER} || 'postgres',
        pass => $ENV{POSTGRES_PASSWORD} || 'postgres',
    };

    # Получаем адрес для поиска
    my $address = $req->param('address') || '';

    # Загружаем шаблон
    my $html = _load_template();

    # Заменяем плейсхолдер адреса
    $html =~ s/\{\{ADDRESS\}\}/@{[_escape_html($address)]}/g;

    my $results_html = '';

    if ($address) {
        # Подключение к БД
        my $dsn = sprintf(
            "DBI:Pg:dbname=%s;host=%s;port=%s",
            $db_config->{name},
            $db_config->{host},
            $db_config->{port}
        );
        my $dbh = DBI->connect($dsn, $db_config->{user}, $db_config->{pass}, {
            RaiseError => 1,
            AutoCommit => 1,
            pg_enable_utf8 => 1,
        }) or die "Cannot connect to database: $DBI::errstr\n";

        # Сначала находим все int_id из log, где address совпадает с искомым адресом получателя
        # Затем для этих int_id получаем записи из обеих таблиц
        my $search_pattern = "%$address%";

        # Получаем записи: сначала из log (где найден адрес получателя),
        # затем из message (для тех же int_id)
        my $query = qq{
            select created, str, int_id, 'log' as source
            from log
            where address ilike ?
            union all
            select m.created, m.str, m.int_id, 'message' as source
            from message m
            where m.int_id in (
                select distinct l.int_id
                from log l
                where l.address ilike ?
            )
            order by int_id, created
            limit 100
        };

        my $sth = $dbh->prepare($query);
        $sth->execute($search_pattern, $search_pattern);

        my @results;
        while (my $row = $sth->fetchrow_hashref) {
            push @results, $row;
        }

        # Проверяем, есть ли еще записи сверх лимита
        my $total_count_query = qq{
            select count(*) as total
            from (
                select created, str, int_id
                from log
                where address ilike ?
                union all
                select m.created, m.str, m.int_id
                from message m
                where m.int_id in (
                    select distinct l.int_id
                    from log l
                    where l.address ilike ?
                )
            ) as combined
        };
        my $total_sth = $dbh->prepare($total_count_query);
        $total_sth->execute($search_pattern, $search_pattern);
        my $total_count = $total_sth->fetchrow_hashref->{total};

        $dbh->disconnect;

        # Формируем HTML результатов
        $results_html = "<div class='results'>\n";

        if (@results) {
            my $count = scalar @results;
            $results_html .= "<div class='count'>Найдено записей: $count";
            if ($total_count > 100) {
                $results_html .= " (показаны первые 100 из $total_count найденных)";
            }
            $results_html .= "</div>\n";

            for my $result (@results) {
                my $created = _escape_html($result->{created});
                my $str = _escape_html($result->{str});

                $results_html .= "<div class='result-item'>";
                $results_html .= "<span class='timestamp'>[$created]</span> ";
                $results_html .= "$str";
                $results_html .= "</div>\n";
            }

            if ($total_count > 100) {
                $results_html .= "<div class='no-results'>Показаны первые 100 результатов из $total_count найденных. Попробуйте уточнить поиск.</div>\n";
            }
        } else {
            $results_html .= "<div class='no-results'>Записи не найдены.</div>\n";
        }

        $results_html .= "</div>\n";
    }

    # Заменяем плейсхолдер результатов
    $html =~ s/\{\{RESULTS\}\}/$results_html/g;

    # Конвертируем UTF-8 строку в байты для Plack
    my $bytes = Encode::encode_utf8($html);

    return [200, ['Content-Type' => 'text/html; charset=utf-8'], [$bytes]];
};
