package App::BencherUtils;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::Any::IfLOG '$log';

use Data::Clean::JSON;
use Function::Fallback::CoreOrPP qw(clone);
use Perinci::Object;
use Perinci::Sub::Util qw(err);
use PerlX::Maybe;
use POSIX qw(strftime);

our %SPEC;

$SPEC{':package'} = {
    v => 1.1,
    summary => 'Utilities related to bencher',
};

my %args_common = (
    result_dir => {
        summary => 'Directory to store results files in',
        schema => 'str*',
        req => 1,
    },
);

my %args_common_query = (
    query => {
        schema => ['array*', of=>'str*'],
        pos => 0,
        greedy => 1,
    },
    detail => {
        schema => 'bool',
        cmdline_aliases => {l=>{}},
    },
);

sub _clean {
    state $cleanser = Data::Clean::JSON->get_cleanser;
    $cleanser->clone_and_clean($_[0]);
}

sub _json {
    state $json = do {
        require JSON::MaybeXS;
        my $json = JSON::MaybeXS->new;
        $json->convert_blessed(1);
        $json->allow_nonref(1);
        $json->canonical(1);
    };
    $json;
}

sub _encode_json {
    no strict 'refs';
    no warnings 'once';
    local *version::TO_JSON = sub { "$_[0]" };
    _json->encode($_[0]);
}

sub _complete_scenario_module {
    require Complete::Module;
    my %args = @_;
    Complete::Module::complete_module(
        word=>$args{word}, ns_prefix=>'Bencher::Scenario');
}

my $re_filename = qr/\A
                     (\w+(?:-(?:\w+))*)
                     (\.module_startup)?
                     \.(\d\d\d\d)-(\d\d)-(\d\d)T(\d\d)-(\d\d)-(\d\d)
                     \.json
                     \z/x;

sub _complete_scenario_in_result_dir {
    require Complete::Util;

    my %args = @_;
    my $word = $args{word};
    my $cmdline = $args{cmdline};
    my $r = $args{r};

    return undef unless $cmdline;

    $r->{read_config} = 1;

    my $res = $cmdline->parse_argv($r);
    return undef unless $res->[0] == 200;

    # combine from command-line and from config/env
    my $final_args = { %{$res->[2]}, %{$args{args}} };
    #$log->tracef("final args=%s", $final_args);

    return [] unless $final_args->{result_dir};

    my %scenarios;

    opendir my($dh), $final_args->{result_dir} or return undef;
    for my $filename (readdir $dh) {
        $filename =~ $re_filename or next;
        my $sc = $1; $sc =~ s/-/::/g;
        $scenarios{$sc}++;
    }

    Complete::Util::complete_hash_key(hash=>\%scenarios, word=>$word);
}

$SPEC{list_bencher_results} = {
    v => 1.1,
    summary => "List results in results directory",
    args => {
        %args_common,
        %args_common_query,

        include_scenarios => {
            'x.name.is_plural' => 1,
            schema => ['array*', of=>'str*'],
            tags => ['category:filtering'],
            element_completion => \&_complete_scenario_in_result_dir,
        },
        exclude_scenarios => {
            'x.name.is_plural' => 1,
            schema => ['array*', of=>'str*'],
            tags => ['category:filtering'],
            element_completion => \&_complete_scenario_in_result_dir,
        },
        module_startup => {
            schema => 'bool*',
            tags => ['category:filtering'],
        },
        latest => {
            'summary.alt.bool.yes' => 'Only list the latest result for every scenario+CPU',
            'summary.alt.bool.no'  => 'Do not list the latest result for every scenario+CPU',
            schema => ['bool*'],
            tags => ['category:filtering'],
        },

        fmt => {
            summary => 'Display each result with bencher-fmt',
            schema => 'bool*',
            tags => ['category:display'],
        },
    },
    examples => [
        {
            summary => 'List all results',
            src => 'list-bencher-results',
            src_plang => 'bash',
            test => 0,
            'x.doc.show_result' => 0,
        },
        {
            summary => 'List all results, show detail information',
            src => 'list-bencher-results -l',
            src_plang => 'bash',
            test => 0,
            'x.doc.show_result' => 0,
        },
        {
            summary => 'List matching results only',
            src => 'list-bencher-results --exclude-scenario Perl::Startup Startup',
            src_plang => 'bash',
            test => 0,
            'x.doc.show_result' => 0,
        },
        {
            summary => 'List matching results, format all using bencher-fmt',
            src => 'list-bencher-results --exclude-scenario Perl::Startup Startup --fmt',
            src_plang => 'bash',
            test => 0,
            'x.doc.show_result' => 0,
        },
        {
            summary => 'List latest result for each scenario+CPU',
            src => 'list-bencher-results QUERY --latest',
            src_plang => 'bash',
            test => 0,
            'x.doc.show_result' => 0,
        },
        {
            summary => 'Delete old results',
            src => 'cd $RESULT_DIR; list-bencher-results --no-latest | xargs rm',
            src_plang => 'bash',
            test => 0,
            'x.doc.show_result' => 0,
        },
    ],
};
sub list_bencher_results {
    require File::Slurper;

    my %args = @_;

    my $dir = $args{result_dir};

    opendir my($dh), $dir or return [500, "Can't read result_dir `$dir`: $!"];

    # normalize
    my $include_scenarios = [
        map {s!/!::!g; $_} @{ $args{include_scenarios} // [] }
    ];
    my $exclude_scenarios = [
        map {s!/!::!g; $_} @{ $args{exclude_scenarios} // [] }
    ];

    my %latest; # key = module+(module_startup)+cpu, value = latest row
    my @rows;
  FILE:
    for my $filename (sort readdir $dh) {
        next unless $filename =~ $re_filename;
        my $row = {
            filename => $filename,
            scenario => $1,
            module_startup => $2 ? 1:0,
            time => "$3-$4-$5T$6:$7:$8",
        };
        $row->{scenario} =~ s/-/::/g;
        if (@$include_scenarios) {
            next FILE unless grep {$row->{scenario} eq $_} @$include_scenarios;
        }
        if (@$exclude_scenarios) {
            next FILE if grep {$row->{scenario} eq $_} @$exclude_scenarios;
        }

        my $benchres = _json->decode(File::Slurper::read_text("$dir/$filename"));
        $row->{res} = $benchres;
        $row->{cpu} = $benchres->[3]{'func.cpu_info'}[0]{name};

        $row->{module_startup} = 1 if $benchres->[3]{'func.module_startup'};

        if (defined $args{module_startup}) {
            next FILE if $row->{module_startup} xor $args{module_startup};
        }

        my $key = sprintf(
            "%s.%s.%s",
            $row->{scenario},
            $row->{module_startup} ? 0:1,
            $row->{cpu} // '', # when bencher is run --no-return-meta, there's no cpu information
        );

        if ($args{query} && @{ $args{query} }) {
            my $matches = 1;
          QUERY_WORD:
            for my $q (@{ $args{query} }) {
                my $lq = lc($q);
                if (index(lc($row->{cpu} // ''), $lq) == -1 &&
                        index(lc($row->{filename}), $lq) == -1 &&
                        index(lc($row->{scenario}), $lq) == -1
                ) {
                    $matches = 0;
                    last;
                }
            }
            next unless $matches;
        }

        if (!$latest{$key} || $latest{$key}{time} lt $row->{time}) {
            $latest{$key} = $row;
        }
        $row->{_key} = $key;

        push @rows, $row;
    }

    # we do the 'latest' filter here after we get all the rows
    if (defined $args{latest}) {
        my @rows0 = @rows;
        @rows = grep {
            my $latest_time = $latest{ $_->{_key} }{time};
            $args{latest} ?
                $_->{time} eq $latest_time :
                $_->{time} ne $latest_time;
        } @rows;
    }

    for (@rows) { delete $_->{_key} }

    my $resmeta = {};
    if ($args{fmt}) {
        require Bencher::Backend;

        $resmeta->{'cmdline.skip_format'} = 1;
        my @content;
        for my $row (@rows) {
            push @content, "$row->{filename} (cpu: ", ($row->{cpu}//''), "):\n";
            push @content, Bencher::Backend::format_result($row->{res});
            push @content, "\n";
        }
        return [200, "OK", join("", @content), $resmeta];
    } else {
        delete($_->{res}) for @rows;
        if ($args{detail}) {
            $resmeta->{'table.fields'} = [qw(scenario module_startup time cpu filename)];
        } else {
            @rows = map {$_->{filename}} @rows;
        }
        return [200, "OK", \@rows, $resmeta];
    }
}

$SPEC{cleanup_old_bencher_results} = {
    v => 1.1,
    summary => 'Delete old results',
    description => <<'_',

By default it will only keep 1 latest result for each scenario for the same CPU
and the same module versions.

You can use `--dry-run` first to see which files would be deleted without
actually deleting them.

_
    args => {
        %args_common,
        %args_common_query,
        num_keep => {
            summary => 'Number of old results to keep',
            schema  => ['int*', min=>0],
            default => 0,
        },
    },
    features => {
        dry_run => 1,
    },
};
sub cleanup_old_bencher_results {
    require File::Slurper;

    my %args = @_;
    my $num_keep = $args{num_keep} // 0;

    my $res = list_bencher_results(
        detail           => 1,
        maybe result_dir => $args{result_dir},
        maybe query      => $args{query},
    );
    return $res if $res->[0] != 200;

    my @scenarios;
    for my $scenario (@{ $res->[2] }) {
        $scenario->{result} = _json->decode(File::Slurper::read_text(
            "$args{result_dir}/$scenario->{filename}"));
        push @scenarios, $scenario;
    }

    my %filenames; # key = scenario|cpu|module_startup(0|1)|json(module_versions), value = [filename, ...]
    for my $scenario (@scenarios) {
        my $key = join(
            "|",
            $scenario->{scenario},
            $scenario->{cpu} // '',
            $scenario->{module_startup} ? 1:0,
            _encode_json($scenario->{result}[3]{'func.module_versions'}),
        );
        #$log->tracef("key = %s", $key);
        push @{$filenames{$key}}, $scenario->{filename};
    }

    $res = envresmulti();
    for my $key (sort keys %filenames) {
        my $val = $filenames{$key};
        next unless @$val > $num_keep+1;
        $val = [sort @$val];
        for my $f (@{$val}[0..$#{$val}-$num_keep-1]) {
            if ($args{-dry_run}) {
                $log->warnf("[DRY-RUN] Deleting %s ...", $f);
                $res->add_result(200, "OK (dry-run)", {item_id=>$f});
            } else {
                $log->warnf("Deleting %s ...", $f);
                if (unlink "$args{result_dir}/$f") {
                    $res->add_result(200, "OK", {item_id=>$f});
                } else {
                    $log->warnf("Can't unlink '%s': %s", $f, $!);
                    $res->add_result(500, "Can't unlink: $!", {item_id=>$f});
                }
            }
        }
    }
    return $res->as_struct;
}

$SPEC{list_bencher_scenario_modules} = {
    v => 1.1,
    summary => 'List Bencher scenario modules',
    args => {
        query => {
            #schema => ['array*', of=>'str*'],
            schema => 'str*',
            pos => 0,
        },
    },
};
sub list_bencher_scenario_modules {
    require PERLANCAR::Module::List;

    my %args = @_;

    my $res = PERLANCAR::Module::List::list_modules(
        "Bencher::Scenario::", {list_modules=>1, recurse=>1});
    my @res = sort keys %$res;
    for (@res) { s/^Bencher::Scenario::// }

    # XXX allow specifying query e.g. 'Accessors/*'

    [200, "OK", \@res];
}

1;
# ABSTRACT:

=head1 SYNOPSIS

=head1 DESCRIPTION

This distribution includes several utilities:

#INSERT_EXECS_LIST
