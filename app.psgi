#!/usr/bin/env perl
use strict;
use warnings;
use Plack::Builder;
use Plack::App::File;

# Загружаем PSGI приложение для поиска
my $search_app = do '/app/search.psgi';

builder {
    # Поиск
    mount "/search" => $search_app;

    # Статические файлы
    mount "/" => Plack::App::File->new(root => "/app")->to_app;
};
