#!/usr/bin/env perl
# Copyright 2014 Michal Špaček <tupinek@gmail.com>

# Pragmas.
use strict;
use warnings;

# Modules.
use Database::DumpTruck;
use Digest::MD5;
use Encode qw(decode_utf8 encode_utf8);
use English;
use File::Temp qw(tempfile);
use HTML::TreeBuilder;
use LWP::UserAgent;
use POSIX qw(strftime);
use URI;
use Time::Local;

# Don't buffer.
$OUTPUT_AUTOFLUSH = 1;

# URI of service.
my $base_uri = URI->new('http://www.sever.brno.cz/povinne-poskytovane-informace.html');

# Open a database handle.
my $dt = Database::DumpTruck->new({
	'dbname' => 'data.sqlite',
	'table' => 'data',
});

# Create a user agent object.
my $ua = LWP::UserAgent->new(
	'agent' => 'Mozilla/5.0',
);

# Get base root.
print 'Page: '.$base_uri->as_string."\n";
my $root = get_root($base_uri);

# Look for items.
my $act_year = (localtime)[5] + 1900;
foreach my $year (2010 .. $act_year) {
	print "Year: $year\n";
	my $year_div = get_h3_content($year);
	process_year_block($year, $year_div);
}

# Get database date from div.
sub get_db_date_div_hack {
	my $date_div = shift;
	my ($day, $mon, $year) = $date_div =~ m/^.*?(\d{2}).*?(\d{2}).*?(\d{4}).*?$/ms;
	if (! defined $day) {
		($day, $mon, $year) = $date_div =~ m/^.*?(\d{2}).*?(\d{1}).*?(\d{4}).*?$/ms;
	}
	if (! defined $day) {
		($day, $mon, $year) = $date_div =~ m/^.*?(\d{1}).*?(\d{2}).*?(\d{4}).*?$/ms;
	}
	if (! defined $day) {
		($day, $mon, $year) = $date_div =~ m/^.*?(\d{1}).*?(\d{1}).*?(\d{4}).*?$/ms;
	}
	remove_trailing(\$day);
	remove_trailing(\$mon);
	remove_trailing(\$year);
	my $time = timelocal(0, 0, 0, $day, $mon - 1, $year - 1900);
	return strftime('%Y-%m-%d', localtime($time));
}

# Get content after h3 defined by title.
sub get_h3_content {
	my $title = shift;
	my @a = $root->find_by_tag_name('a');
	my $ret_a;
	foreach my $a (@a) {
		if ($a->as_text eq $title) {
			$ret_a = $a;
			last;
		}
	}
	my @content = $ret_a->parent->parent->content_list;
	my $num = 0;
	foreach my $content (@content) {
		if ($num == 1) {
			return $content;
		}
		if (check_h3($content, $title)) {
			$num = 1;
		}
	}
	return;
}

# Check if is h3 with defined title.
sub check_h3 {
	my ($block, $title) = @_;
	foreach my $a ($block->find_by_tag_name('a')) {
		if ($a->as_text eq $title) {
			return 1;
		}
	}
	return 0;
}

# Get root of HTML::TreeBuilder object.
sub get_root {
	my $uri = shift;
	my $get = $ua->get($uri->as_string);
	my $data;
	if ($get->is_success) {
		$data = $get->content;
	} else {
		die "Cannot GET '".$uri->as_string." page.";
	}
	my $tree = HTML::TreeBuilder->new;
	$tree->parse(decode_utf8($data));
	return $tree->elementify;
}

# Get link and compute MD5 sum.
sub md5 {
	my $link = shift;
	my (undef, $temp_file) = tempfile();
	my $get = $ua->get($link, ':content_file' => $temp_file);
	my $md5_sum;
	if ($get->is_success) {
		my $md5 = Digest::MD5->new;
		open my $temp_fh, '<', $temp_file;
		$md5->addfile($temp_fh);
		$md5_sum = $md5->hexdigest;
		close $temp_fh;
		unlink $temp_file;
	}
	return $md5_sum;
}

# Process year block.
sub process_year_block {
	my ($year, $year_div) = @_;
	foreach my $tr ($year_div->find_by_tag_name('tr')) {
		my @td = $tr->find_by_tag_name('td');
		my $date = get_db_date_div_hack($td[0]->as_text);
		my @title_a = $td[1]->find_by_tag_name('a');
		foreach my $title_a (@title_a) {
			my $title = $title_a->as_text;
			remove_trailing(\$title);
			my $pdf_link = $base_uri->scheme.'://'.$base_uri->host.
				$title_a->attr('href');

			# Save.
			my $ret_ar = eval {
				$dt->execute('SELECT COUNT(*) FROM data '.
					'WHERE PDF_link = ?', $pdf_link);
			};
			if ($EVAL_ERROR || ! @{$ret_ar}
				|| ! exists $ret_ar->[0]->{'count(*)'}
				|| ! defined $ret_ar->[0]->{'count(*)'}
				|| $ret_ar->[0]->{'count(*)'} == 0) {

				my $md5 = md5($pdf_link);
				if (! defined $md5) {
					print "Cannot get PDF for $date: ".
						encode_utf8($title)."\n";
				} else {
					print "$date: ".encode_utf8($title)."\n";
					$dt->insert({
						'Date' => $date,
						'Title' => $title,
						'PDF_link' => $pdf_link,
						'MD5' => $md5,
					});
					# TODO Move to begin with create_table().
					$dt->create_index(['PDF_link'], 'data', 1, 1);
					$dt->create_index(['MD5'], 'data', 1, 0);
				}
			}
		}
	}
	return;
}

# Removing trailing whitespace.
sub remove_trailing {
	my $string_sr = shift;
	${$string_sr} =~ s/^\s*//ms;
	${$string_sr} =~ s/\s*$//ms;
	return;
}
