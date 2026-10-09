#!/usr/bin/env perl
# Print one problem per line when a pull request description leaves "## What changed"
# or "## Why" without a sentence or two of its own, or nothing when both are filled in.
# .github/scripts/check_pr.sh runs it with PR_BODY set to the description and
# PR_TEMPLATE to .github/pull_request_template.md, whose hint comments do not count.
use strict;
use warnings;
use feature qw(unicode_strings);
binmode STDOUT, ":encoding(UTF-8)";

my @required = ("What changed", "Why");
my %known = map { lc($_) => 1 } (@required, "Checked");
my $min_words = 2;

# A word is two or more letters, digits, or apostrophes with at least one letter ("2x" counts,
# "12" does not), or one CJK character.
my $cjk = qr/[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]/;
my $letter = qr/(?:(?!$cjk)\p{L})/;
my $token = qr/$cjk|$letter(?:$letter|[\p{M}\p{N}\x27\x{2019}])*|\p{N}+(?:$letter(?:$letter|[\p{M}\p{N}])*)?/;
sub key_of { return lc join " ", $_[0] =~ /$token/g }
sub word_count { return scalar grep { /^$cjk$/ or (length($_) >= 2 and /\p{L}/) } $_[0] =~ /$token/g }

# Whole-section placeholders, compared after key_of(): "TODO: fill in later" -> "todo fill in later".
my $ph = qr/todo|to do|tbd|tbc|tba|tk|wip|work in progress|n ?a|none|nothing|nil|null|x+|placeholder|lorem ipsum(?: \S+)*|ditto|obvious|self explanatory|not applicable|no description|description|coming soon|later|(?:will )?fill (?:me |this |it )?in|to be (?:filled|added|written|done|determined)(?: in)?|(?:see|refer to|same as|as in|as per|per)(?: the)?(?: pr| commit)? (?:title|commits?|commit messages?|messages?|log|above|below|description|diff|changes|code)|(?:as )?titled|as above|same as above|title says it all|(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|refs?|see|part of|related to)(?: issue)? \d+/;
my $placeholder = qr/^(?:$ph)(?: (?:$ph))*$/;

# Hint comments from the PR template, so hints left in as plain text do not count as a description.
my %hint;
if (defined $ENV{PR_TEMPLATE} and open my $fh, "<", $ENV{PR_TEMPLATE}) {
  local $/;
  my $t = <$fh>;
  utf8::decode($t);
  $hint{key_of($_)} = 1 for $t =~ /<!--(.*?)-->/gs;
  delete $hint{""};
}

# Text a reader sees as a description: no footers, checklists, images, URLs, tags, or entities.
sub prose {
  local $_ = shift;
  s/^[ \t]*(?:\x{1F916}[ \t]*)?Generated with \[?(?:Claude Code|Codex)\]?(?:\([^)]*\))?[ \t.]*$//mgi;
  s/^[ \t]*(?:Co-authored-by|Signed-off-by|Claude-Session|Reviewed-by|Acked-by|Tested-by|Reported-by|Suggested-by|Change-Id):.*$//mgi;
  s/^[ \t>]*(?:[-*+]|\d{1,9}[.)])[ \t]+\[[ xX]\](?:[ \t].*)?$//mg;
  s/!\[[^\[\]]*\]\([^()]*\)//g;
  s/<img\b[^>]*>//gi;
  s/\[([^\[\]]*)\]\([^()]*\)/$1/g;
  s{<?\b(?:https?|ftp)://[^\s<>]*>?}{ }gi;
  s/<\/?[A-Za-z][^>]*>/ /g;
  s/&(?:[A-Za-z][A-Za-z0-9]*|#[0-9]+|#[xX][0-9A-Fa-f]+);/ /g;
  return $_;
}

# Remove closed comments. Only text before the last "-->" can hold one, which keeps
# a run of unclosed "<!--" from taking quadratic time.
sub uncomment {
  my $s = shift;
  my $last = rindex $s, "-->";
  return $s if $last < 0;
  (my $head = substr $s, 0, $last + 3) =~ s/<!--(?:-?>|.*?-->)//gs;
  return $head . substr($s, $last + 3);
}

my $body = defined $ENV{PR_BODY} ? $ENV{PR_BODY} : "";
utf8::decode($body);
$body =~ s/\r\n?/\n/g;

# Walk the Markdown the way GitHub renders it: fenced code shows literally and has no headings;
# a comment that starts a line hides everything up to its "-->", or to the end when it never closes;
# a comment inside a paragraph hides only when it closes in that paragraph.
my (%text, %seen, @others, @para);
my ($cur, $cur_level, $fence, $hidden) = ("", 0, "", 0);
my $flush = sub {
  return unless @para;
  my $p = join "\n", @para;
  @para = ();
  my @code;
  $p =~ s{(`+)(.+?)(?<!`)\1(?!`)}{push @code, $2; "\x{E000}" . $#code . "\x{E001}"}gse;
  $p = uncomment($p);
  $p =~ s/\x{E000}(\d+)\x{E001}/$code[$1]/g;
  $text{$cur} .= "$p\n" if length $cur;
};
for my $line (split /\n/, $body) {
  if ($hidden) {
    my $end = index $line, "-->";
    next if $end < 0;
    $hidden = 0;
    push @para, substr($line, $end + 3);
    $flush->();
    next;
  }
  if (length $fence) {
    my ($char, $len) = (substr($fence, 0, 1), length $fence);
    $fence = "" if $line =~ /^ {0,3}(?:\Q$char\E){$len,}[ \t]*$/;
    next;
  }
  if ($line =~ /^ {0,3}(`{3,}|~{3,})(.*)$/ and not (substr($1, 0, 1) eq "`" and $2 =~ /`/)) {
    $flush->();
    $fence = $1;
    next;
  }
  if ($line =~ /^ {0,3}<!--/) {
    $flush->();
    $line = uncomment($line);
    my $start = index $line, "<!--";
    if ($start >= 0) {
      $line = substr $line, 0, $start;
      $hidden = 1;
    }
    push @para, $line;
    $flush->();
    next;
  }
  if ($line =~ /^ {0,3}(#{1,6})(?:[ \t]|$)/) {
    my ($level, $name) = (length $1, substr $line, $+[0]);
    $flush->();
    # Heading text without comments, emphasis, closing #s, or punctuation and emoji at either end.
    $name = uncomment($name);
    $name =~ s/[*_`]+//g;
    $name = $name =~ /^[^\p{L}\p{N}]*+(.*[\p{L}\p{N}])/s ? $1 : "";
    $name =~ s/\s+/ /g;
    my $key = lc $name;
    # GitHub's generated release notes say "What's changed".
    $key =~ s/^what(?:\x27|\x{2019})?s changed$/what changed/;
    if ($known{$key}) {
      ($cur, $cur_level) = ($key, $level);
      $seen{$key} = 1;
      $text{$key} .= "";
    } else {
      push @others, ("#" x $level) . " $name" if length $name;
      ($cur, $cur_level) = ("", 0) if length $cur and $level <= $cur_level;
    }
    next;
  }
  if ($line !~ /\S/) {
    $flush->();
    next;
  }
  push @para, $line;
}
$flush->();

my (%key, @problems);
my $found = @others ? "; found " . join(", ", map { "\"$_\"" } grep { defined } @others[0 .. 3]) : "";
for my $name (@required) {
  my $k = lc $name;
  my $where = "\"## $name\"";
  if (!$seen{$k}) {
    push @problems, "Add a $where section (the PR template has it)$found.";
    next;
  }
  my $prose = prose($text{$k});
  (my $shown = $prose) =~ s/\s+/ /g;
  $shown =~ s/^ | $//g;
  $shown = substr($shown, 0, 40) . "..." if length $shown > 43;
  $key{$k} = key_of($prose);
  if ($key{$k} eq "") {
    push @problems, "Fill in the $where section.";
  } elsif ($key{$k} =~ $placeholder) {
    push @problems, "Replace the placeholder \"$shown\" in $where with a sentence or two.";
  } elsif ($hint{$key{$k}}) {
    push @problems, "Replace the template hint in $where with your own words.";
  } elsif (word_count($prose) < $min_words) {
    push @problems, "Say more than \"$shown\" in $where: a sentence or two.";
  }
}
if (!@problems and $key{"why"} eq $key{"what changed"}) {
  push @problems, "\"## Why\" repeats \"## What changed\"; say why the change is needed.";
}
print "$_\n" for @problems;
