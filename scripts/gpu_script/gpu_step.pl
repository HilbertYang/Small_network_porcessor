#!/usr/bin/env perl
use strict;
use warnings;

my $GPUREG = "perl ./gpureg.pl";

sub g {
  my ($cmd) = @_;
  system("$GPUREG $cmd") == 0 or die "Failed: $cmd\n";
}

sub do_steps {
  my ($n) = @_;
  for my $i (1..$n) {
    g("step");
  }
  g("dbg");
}

print "=== GPU Interactive Stepper ===\n";
print "Commands:\n";
print "  <n>       step N cycles then show PC/instr\n";
print "  d <addr>  read DMEM[addr]\n";
print "  done      check done flag\n";
print "  dbg       show PC + IF_INSTR\n";
print "  q         quit\n\n";

while (1) {
  print "step> ";
  my $line = <STDIN>;
  last unless defined $line;
  chomp $line;
  $line =~ s/^\s+|\s+$//g;

  next if $line eq '';

  if ($line eq 'q' || $line eq 'quit') {
    last;

  } elsif ($line =~ /^(\d+)$/) {
    my $n = int($1);
    if ($n < 1) { print "Enter a positive integer.\n"; next; }
    print "--- stepping $n cycle(s) ---\n";
    do_steps($n);

  } elsif ($line =~ /^d\s+(\S+)$/) {
    g("dmem_read $1");

  } elsif ($line eq 'done') {
    g("done_check");

  } elsif ($line eq 'dbg') {
    g("dbg");

  } else {
    print "Unknown command: $line\n";
  }
}

print "Bye.\n";
