#!/usr/bin/perl
# Owner: QA. Runs a command with a time limit: scripts/with-timeout.pl <seconds> <command...>
# On timeout it kills the command's whole tree, including processes that left its process group
# (swift test starts swiftpm-testing-helper, which would otherwise survive as an orphan of launchd
# and keep burning CPU). Exit: the command's status, 124 on timeout.
use strict; use warnings;
my $t = shift @ARGV;
my $pid = fork // die "fork: $!";
if (!$pid) { setpgrp(0, 0); exec @ARGV or die "exec $ARGV[0]: $!" }

sub tree {   # the pid and all its descendants, collected while the tree is still intact
    my ($p) = @_;
    my @kids = grep { /^\d+$/ } split /\n/, `pgrep -P $p 2>/dev/null`;
    return ($p, map { tree($_) } @kids);
}
local $SIG{ALRM} = sub {
    my @all = tree($pid);
    kill 'TERM', @all; kill 'TERM', -$pid;
    sleep 2;
    kill 'KILL', grep { kill 0, $_ } @all;
    print STDERR "\nTIMEOUT after ${t}s (killed " . scalar(@all) . " processes)\n";
    exit 124;
};
alarm $t;
waitpid $pid, 0;
exit($? >> 8 || ($? & 127 ? 128 + ($? & 127) : 0));
