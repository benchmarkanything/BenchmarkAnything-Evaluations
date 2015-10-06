use 5.010; # Perl 5.10+ needed for PDL/PDLA
use strict;
use warnings;
package BenchmarkAnything::Evaluations;
# ABSTRACT: Evaluation support for BenchmarkAnything data

use PDLA::Core;
use PDLA::Stats;
use PDLA::Ufunc;

=head2 multi_point_stats (\@values)

For an array of values it gets basic statistical aggregations, like
average, standard deviation, and confidence interval.

=cut

sub multi_point_stats
{
        my ($values) = @_;

        my $data = pdl(@$values);
        my $avg  = average($data);
        return {
                avg         => sclr($avg),
                stdv        => stdv($data),
                min         => min($data),
                max         => max($data),
                ci_95_lower => $avg - 1.96 * se($data),
                ci_95_upper => $avg + 1.96 * se($data),
               };
}

=head2 transform_chartlines ($chartlines, $options)

Gets an array of query results, each one from a different query
against the backend store, and returns a matrix for rendering those
chartlines, currently suited for the google charts api.

Multiple results for the same data X-axis are aggregated (default:
avg).

=over 4

=item INPUT:

  [ title: "dpath-T-n64",
    results: [
      {N:dpath, V:1000, version:2.0.13},
      {N:dpath, V:1170, version:2.0.14},
      {N:dpath,  V:660, version:2.0.15},
      {N:dpath, V:1030, version:2.0.16}
    ]
  ],
  [ title: "Mem-nT-n64",
    results: [
      {N:Mem,    V:400, version:2.0.13},
      {N:Mem,    V:460, version:2.0.14},
      {N:Mem,   V:1120, version:2.0.15},
      {N:Mem,    V:540, version:2.0.16}
    ]
  ],
  [ title: "Fib-T-64",
    results: [
      {N:Fib,    V:100, version:2.0.13},
      {N:Fib,    V:100, version:2.0.14},
      {N:Fib,    V:100, version:2.0.15},
      {N:Fib,    V:200, version:2.0.16}
    ]
  ]

=item OUTPUT:

   # multiple results for same version would become aggregated (avg), not show here
  ['version',   'dpath', 'Mem', 'Fib'],
  ['2.0.13',      1000,   400,   100],
  ['2.0.14',      1170,   460,   100],
  ['2.0.15',       660,  1120,   100],
  ['2.0.16',      1030,   540,   200]

=back

There are assumptions for the transformation:

=over 4

=item * there is only one NAME per chartline resultset

=item * titles are unique

=back

=cut

sub transform_chartlines
{
        my ($chartlines, $options) = @_;

        my $x_key       = $options->{x_key};
        my $x_type      = $options->{x_type};
        my $y_key       = $options->{y_key};
        my $y_type      = $options->{y_type};
        my $aggregation = $options->{aggregation};
        my $verbose     = $options->{verbose};
        my $debug       = $options->{debug};
        my $dropnull    = $options->{dropnull};

        # from all chartlines collect values into buckets for the dimensions we need
        #
        # chartline = title
        # x         = perlconfig_version
        # y         = VALUE
        my @titles;
        my %VALUES;
 CHARTLINE:
        foreach my $chartline (@$chartlines)
        {
                my $title     = $chartline->{title};
                my $results   = $chartline->{results};
                my $NAME      = $results->[0]{NAME};

                # skip typical empty results
                if (not @$results or (@$results == 1 and not $results->[0]{NAME}))
                {
                        print STDERR "benchmarkanything: transform_chartlines: ignore empty chartline '$title'\n" if $verbose;
                        next CHARTLINE;
                }
                push @titles, $title;

                print STDERR sprintf("* %-20s - %-40s\n", $title, $NAME) if $verbose;
                print STDERR "  VALUE_IDs: ".join(",", map {$_->{VALUE_ID}} @$results)."\n" if $debug;

        POINT:
                foreach my $point (@$results)
                {
                        my $x = $point->{$x_key};
                        my $y = $point->{$y_key};
                        if (not defined $x)
                        {
                                require Data::Dumper;
                                print STDERR "benchmarkanything: transform_chartlines: chartline '$title': ignore data point (missing key '$x_key'): ".Data::Dumper::Dumper($results) if $verbose;
                                next POINT;
                        }
                        push @{$VALUES{$title}{$x}{values}}, $y; # maybe multiple for same X - average them later
                }
        }

        # statistical aggregations of multi points
        foreach my $title (keys %VALUES)
        {
                foreach my $x (keys %{$VALUES{$title}})
                {
                        my $multi_point_values     = $VALUES{$title}{$x}{values};
                        $VALUES{$title}{$x}{stats} = multi_point_stats($multi_point_values);
                }
        }

        # find out all available x-values from all chartlines
        my %all_x;
        foreach my $title (keys %VALUES)
        {
                foreach my $x (keys %{$VALUES{$title}})
                {
                        $all_x{$x} = 1;
                }
        }
        my @all_x = keys %all_x;
        @all_x =
         $x_type eq 'version'    ? sort {version->parse($a) <=> version->parse($b)} @all_x
          : $x_type eq 'numeric' ? sort {$a <=> $b} @all_x
           : $x_type eq 'string' ? sort {$a cmp $b} @all_x
            : $x_type eq 'date'  ? sort { die "TODO: sort by date" ; $a cmp $b} @all_x
             : @all_x;

        # drop complete chartlines if it has gaps on versions that the other chartlines provide values
        my %clean_chartlines;
        if ($dropnull) {
                foreach my $title (keys %VALUES) {
                        my $ok = 1;
                        foreach my $x (@all_x) {
                                if (not @{$VALUES{$title}{$x}{values} || []}) {
                                        print STDERR "skip: $title (missing values for $x)\n" if $verbose;
                                        $ok = 0;
                                }
                        }
                        if ($ok) {
                                $clean_chartlines{$title} = 1;
                                print STDERR "okay: $title\n" if $verbose;
                        }
                }
        }

        # intermediate debug output
        foreach my $title (keys %VALUES)
        {
                foreach my $x (keys %{$VALUES{$title}})
                {
                        my $count = scalar @{$VALUES{$title}{$x}{values} || []} || 0;
                        next if not $count;
                        my $avg   = $VALUES{$title}{$x}{stats}{avg};
                        my $stdv  = $VALUES{$title}{$x}{stats}{stdv};
                        my $ci95l = $VALUES{$title}{$x}{stats}{ci_95_lower};
                        my $ci95u = $VALUES{$title}{$x}{stats}{ci_95_upper};
                        print STDERR sprintf("  %-20s . %-7s . (ci95l..avg..ci95u) = (%2.2f .. %2.2f .. %2.2f) +- stdv %5.2f (%3d points)\n", $title, $x, $ci95l, $avg, $ci95u, $stdv, $count) if $verbose;
                }
        }

        # result data structure, as needed per chart type
        my @RESULTMATRIX;

        @titles = grep { !$dropnull or $clean_chartlines{$_} } @titles; # dropnull

        for (my $i=0; $i<@all_x; $i++)          # rows
        {
                my $x = $all_x[$i];
                for (my $j=0; $j<@titles; $j++) # columns
                {
                        my $title = $titles[$j];
                        my $value = $VALUES{$title}{$x}{stats}{$aggregation};
                        # stringify to unbless from PDL, then numify for type-aware JSON
                        $value    = $value ? (0+sprintf("%6.2f", $value)) : undef;
                        $RESULTMATRIX[0]    [0]    = $x_key       if $i == 0 && $j == 0;
                        $RESULTMATRIX[0]    [$j+1] = $title       if $i == 0;
                        $RESULTMATRIX[$i+1] [0]    = $x           if            $j == 0;
                        $RESULTMATRIX[$i+1] [$j+1] = $value;
                }
        }
        return \@RESULTMATRIX;
}

1;
