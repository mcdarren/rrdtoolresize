#!/usr/bin/perl
use strict;
use warnings;
use RRDs;
use Time::HiRes qw/time/;

my $rrdtool = '/usr/bin/rrdtool';
my $logsdir = 'logs';  # Where all the rrd files live

# The number of data sources in each rrd file
# Typically, for mtrg-generated rrds this will be 8
my $datasources = 8;

my %wanted = (
    1   => 8640,    # 30 days of 5 minute data
    6   => 17520,   # 365 days of 30 min data
    24  => 13140,   # 3 years of 2 hour data
    288 => 3650,    # 10 years of 1 day data
    );

opendir(DIR, $logsdir) or die "Cannot open $logsdir:$!\n";
my @rrds = grep { /.rrd$/ && -f "$logsdir/$_" } readdir DIR;
closedir DIR;
my $numfiles = scalar @rrds;
print "Starting, found $numfiles rrd files\n\n";
my $start = time;

for my $rrd (sort @rrds) {
    print "\nProcessing $rrd\n";
    my $info = RRDs::info "$logsdir/$rrd";
    # Check to ensure we actually have a valid rrd file
    unless ($info->{filename}) {
        print qq|"$logsdir/$rrd" doesn't appear to be a valid rrd log, skipping\n|;
        next;
    }
    for (0 .. $datasources -1) {
        my $cmd = qq|$rrdtool resize $logsdir/$rrd |;
        my $pdp = $info->{"rra[$_].pdp_per_row"};
        my $rows = $info->{"rra[$_].rows"};
        my $cf = $info->{"rra[$_].cf"};
        my $diff = $rows - $wanted{$pdp};
        printf("\tCurrent DS => PDP per row:%.f Rows:%.f CF:%s\n", $pdp, $rows, $cf); 
        if ($diff < 0) {
            $diff = abs($diff);
            $cmd .= qq|$_ GROW $diff|;
        }
        elsif ($diff > 0) {
            $cmd .= qq|$_ SHRINK $diff|;
        }
        else {
            print "\tNo change to this DS\n\n";
            next;
        }

        print "\tResizing to $wanted{$pdp} rows, executing $cmd\n";
        system($cmd) == 0 or die "Could not execute $cmd:$!\n";
        print "\tRenaming resized file\n";
        rename 'resize.rrd', "$logsdir/$rrd";
        print "\tDone.\n";
    }
}

my $end = time;
my $dur = sprintf("%.2f", $end - $start);
print "Finished, processed $numfiles files in $dur seconds\n\n";
