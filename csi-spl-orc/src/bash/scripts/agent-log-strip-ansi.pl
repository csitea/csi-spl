#!/usr/bin/perl
# agent-log-strip-ansi.pl - the filter of an agent's full-output log (spec 160
# section 3.9, SPL-4718): stdin is the raw tmux stream of the agent's pane
# (`tmux pipe-pane`), stdout the text without its terminal escapes. A cursor
# move becomes a newline, an OSC title, a CSI sequence, a charset switch and a
# carriage return are dropped, and a run of blank lines is folded. Unbuffered,
# so the log grows as the pane does. do_spl_agent_log_pipe attaches it.
$|=1; while (sysread(STDIN, my $b, 65536)) {
  $b =~ s/\e\[[0-9;?]*[HfABCDEFGd]/\n/g; $b =~ s/\e\][^\a\e]*(?:\a|\e\\)//g;
  $b =~ s/\e\[[0-9;?]*[ -\/]*[@-~]//g; $b =~ s/\e[()][0-9A-Za-z]//g; $b =~ s/\e[>=78]//g;
  $b =~ s/\r//g; $b =~ s/\n[ \t]*(?=\n)//g; print $b;
}
