
# Drive the actual pg_upgrade path for spock 5.x -> 6.x. This is the
# upgrade.sh scenario, restated as a TAP test using the standard
# PostgreSQL::Test framework.
#
# Bootstrap phase (raw shell, since we are literally building PostgreSQL):
#   - Discover the local PostgreSQL repo (spock lives in contrib/spock,
#     so its parent's parent is the PG source tree). Clone --shared from
#     it twice -- one for old, one for new -- so we never touch the
#     network and tags are already in scope.
#   - Clone the local spock working tree once. Capture HEAD as the "new"
#     ref; flip between $OLD_SPOCK_REF (default origin/v5_STABLE) and
#     that captured ref via `git checkout` between builds.
#   - For each variant: checkout the matching spock ref, apply
#     patches/$PG_MAJOR/*.diff onto the matching PG tree, configure,
#     build, install.
#
# Scenario phase (standard PostgreSQL::Test idioms):
#   - Two PostgreSQL::Test::Cluster nodes with install_path pointing at
#     the freshly-built prefixes.
#   - Old node, regression database: populated by the core `make
#     installcheck` suite -- a broad mix of every object kind pg_upgrade
#     must carry across.
#   - Old node, spock_delta database: spock installed, columns marked with
#     the delta_apply attribute-option form
#         ALTER TABLE t ALTER COLUMN c SET (log_old_value=true,
#                                           delta_apply_function=spock.delta_apply)
#     Both spock 5.x and 6.x store this in pg_attribute.attoptions (the
#     core attoptions patch teaches PostgreSQL the option names), so a
#     correct upgrade carries it across verbatim -- no shim, no rewrite.
#   - command_ok pg_upgrade old -> new.
#   - New node: assert the regression database survived with the same set
#     of user relations, and that every marked delta_apply attoption is
#     carried across unchanged and still names a live spock.delta_apply().
#
# Each run is a clean build: $TEMP_BASE and the per-node data dirs
# from any prior run are wiped at the start. Expect 5-30 minutes per
# run -- caching across runs sounded useful but in practice masked
# failures by carrying corrupted/half-applied state forward.
#
# Run it the same way as every other spock TAP test, via the spock
# Makefile's check_prove target:
#
#     make check_prove PROVE_TESTS=t/030_pg_upgrade_5x_to_6x.pl
#
# That target already exports PG_CONFIG, prepends $(PG_CONFIG --bindir)
# to PATH, and adds PG_PROVE_FLAGS so PostgreSQL::Test::Cluster is
# importable. The test auto-resolves everything else: the PostgreSQL
# source repo (via spock/../..), the PG major (via PG_CONFIG --version),
# and the PG ref (via `git describe --tags --abbrev=0 REL_<major>_STABLE`,
# so REL_17_9 on a shipped branch, REL_18_BETA3 mid-cycle).
#
# Tunable via env (all optional; empty strings are ignored):
#   PG_CONFIG                   path to the pg_config of the build
#                               target. Default: `pg_config` on PATH.
#                               Set by make check_prove already.
#   SPOCK_TEST_PG_REPO          path or URL of the PostgreSQL repo to
#                               clone from. Default: discovered local
#                               repo at ../.. relative to spock (or, as
#                               a fallback, `$PG_CONFIG --srcdir`). No
#                               network fetch in the default path.
#   SPOCK_TEST_PG_BRANCH        PostgreSQL ref to checkout. Override to
#                               pin a specific ref (REL_15_8, master,
#                               my-feature-branch).
#   SPOCK_TEST_OLD_SPOCK_REF    spock ref for OLD cluster (default
#                               origin/v5_STABLE; must be present in the
#                               local clone's remote refs).
#   SPOCK_TEST_TEMP_BASE        bootstrap work dir. Default:
#                               <spock>/tests/tap/tmp_check/030_pg_upgrade
#                               (already in spock's .gitignore). Wiped
#                               at the start of every run.
#   SPOCK_TEST_PG_CONFIGURE     extra ./configure flags.

use strict;
use warnings FATAL => 'all';

use Cwd qw(getcwd abs_path);
use File::Basename qw(basename);
use File::Path qw(make_path remove_tree);

# Locate PostgreSQL's TAP perl modules via pg_config so the test runs
# under a plain `prove t/030_*.pl` (e.g. via tests/tap/run_tests.sh)
# without the caller having to pass `-I .../src/test/perl`. The spock
# Makefile's `make check_prove` path passes PG_PROVE_FLAGS for us, but
# the shell wrapper and direct prove invocations do not.
BEGIN
{
	my $pgc = $ENV{PG_CONFIG};
	$pgc = 'pg_config' if !defined $pgc or $pgc eq '';

	my @candidates;

	my $pgxs = qx('$pgc' --pgxs 2>/dev/null);
	chomp $pgxs if defined $pgxs;
	if (defined $pgxs and $pgxs ne '')
	{
		(my $p = $pgxs) =~ s{/src/makefiles/pgxs\.mk$}{/src/test/perl};
		push @candidates, $p;
	}

	my $srcdir = qx('$pgc' --srcdir 2>/dev/null);
	chomp $srcdir if defined $srcdir;
	push @candidates, "$srcdir/src/test/perl"
	  if defined $srcdir and $srcdir ne '';

	for my $p (@candidates)
	{
		if (-f "$p/PostgreSQL/Test/Cluster.pm")
		{
			unshift @INC, $p;
			last;
		}
	}
}

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Treat empty strings the same as undef. GitHub Actions and similar CI
# systems often expand inputs into env vars verbatim, so a workflow that
# does not pass a value for an optional input ends up exporting the var
# as ''. Plain `//` would not fall back in that case.
sub env_or
{
	my ($name, $default) = @_;
	my $v = $ENV{$name};
	return (defined $v and $v ne '') ? $v : $default;
}

# Path to pg_config: the canonical spock env var PG_CONFIG (used by the
# Makefile too) wins, otherwise rely on `pg_config` on PATH (which
# `make check_prove` sets up via the spock Makefile). If PG_CONFIG is
# an absolute path that does not exist, bail with a specific message --
# a stale export from a prior shell session is the usual cause, and
# silently falling through to a confusing later error is worse UX than
# naming it here.
sub pg_config_bin
{
	my $explicit = env_or('PG_CONFIG', undef);
	return 'pg_config' unless defined $explicit;
	if ($explicit =~ m{/} and !-x $explicit)
	{
		BAIL_OUT("PG_CONFIG='$explicit' but no such executable exists. "
			  . "Likely a stale export from a previous shell session: "
			  . "run `unset PG_CONFIG` (so the test falls back to "
			  . "`pg_config` on PATH) or set PG_CONFIG to a real path.");
	}
	return $explicit;
}

my $configure_flags = env_or('SPOCK_TEST_PG_CONFIGURE',
	'--without-icu --without-readline --without-zlib');
# $old_spock_ref and $temp_base are computed below, after the local
# spock repo is known.

# Locate a local PostgreSQL git repo to clone from.
sub discover_local_pg_repo
{
	my ($spock_repo) = @_;

	my @candidates;
	push @candidates, $ENV{PG_SRCDIR} if defined $ENV{PG_SRCDIR};
	push @candidates, abs_path("$spock_repo/../..");
	push @candidates, abs_path("$spock_repo/../postgres");

	for my $c (@candidates)
	{
		next unless defined $c and $c ne '';
		return $c if -d "$c/.git" and -d "$c/src/backend";
	}

	return undef;
}

# Major from pg_config. PG_CONFIG env var wins; otherwise we look up
# `pg_config` on PATH (which `make check_prove` sets up via the spock
# Makefile). For an explicit SPOCK_TEST_PG_BRANCH override we recover
# the major from the ref itself.
sub detect_pg_major_from_pg_config
{
	my $pgc = pg_config_bin();
	my $ver = qx('$pgc' --version 2>/dev/null);
	return undef if $? != 0;
	return $1 if $ver =~ /\bPostgreSQL\s+(\d+)/;
	return undef;
}

# Latest tag reachable from a given branch. Both PG and spock tag
# every release on their respective STABLE branches, so `git describe
# --tags --abbrev=0` lands on the most recent tag automatically --
# REL_17_9 on a shipped PG, v5.0.7 on origin/v5_STABLE, BETA tags
# mid-cycle. Returns undef if the branch is missing or has no tag
# reachable -- caller falls back to the branch name itself.
sub latest_tag_on_branch
{
	my ($branch, $local_repo) = @_;
	my $tag = qx(git -C '$local_repo' describe --tags --abbrev=0 '$branch' 2>/dev/null);
	return undef if $? != 0;
	chomp $tag;
	return $tag eq '' ? undef : $tag;
}

# Locate the local spock working tree.
my $cwd = getcwd();
my $local_spock_repo;
if    ($cwd =~ m{^(/.+?)/tests/tap/t/?$}) { $local_spock_repo = $1; }
elsif ($cwd =~ m{^(/.+?)/tests/tap/?$})   { $local_spock_repo = $1; }
else { $local_spock_repo = abs_path($cwd); }

BAIL_OUT("cannot find local spock working tree at '$local_spock_repo' "
	  . "(no Makefile)")
  unless -f "$local_spock_repo/Makefile";

# Default work dir: under tests/tap/tmp_check, alongside other spock TAP
# state. tmp_check is in spock's .gitignore and is not in EXTRA_CLEAN,
# so the cache survives `make clean`.
my $temp_base = env_or('SPOCK_TEST_TEMP_BASE',
	"$local_spock_repo/tests/tap/tmp_check/030_pg_upgrade");

my $old_spock_ref = env_or('SPOCK_TEST_OLD_SPOCK_REF', 'origin/v5_STABLE');

# Discover (or accept an override of) the local PostgreSQL repo.
my $pg_repo = env_or('SPOCK_TEST_PG_REPO', undef)
  // discover_local_pg_repo($local_spock_repo)
  // BAIL_OUT('cannot locate local PostgreSQL source repo. spock is '
	  . 'normally cloned under contrib/spock so its parent is the PG '
	  . 'tree; if your layout differs, set SPOCK_TEST_PG_REPO to a path '
	  . 'or URL.');

# Resolve the major (env override -> pg_config) and the ref to checkout
# (env override -> latest stable tag in the local repo -> STABLE branch).
my $env_branch = env_or('SPOCK_TEST_PG_BRANCH', undef);
my $pg_major;
if (defined $env_branch)
{
	($pg_major) = ($env_branch =~ /^REL_?(\d+)/);
	BAIL_OUT("cannot derive PG major version from "
		  . "SPOCK_TEST_PG_BRANCH='$env_branch'")
	  unless $pg_major;
}
else
{
	$pg_major = detect_pg_major_from_pg_config()
	  or BAIL_OUT('cannot determine PG major: pg_config did not return '
		  . "a version. Set PG_CONFIG to a valid pg_config path, or set "
		  . "SPOCK_TEST_PG_BRANCH explicitly (current PG_CONFIG="
		  . (env_or('PG_CONFIG', '<unset>')) . ").");
}

my $pg_branch = $env_branch
  // latest_tag_on_branch("REL_${pg_major}_STABLE", $pg_repo)
  // latest_tag_on_branch('HEAD', $pg_repo)
  // 'HEAD';

BAIL_OUT("local spock has no patches/$pg_major (need patches for the "
	  . "PG major being tested)")
  unless -d "$local_spock_repo/patches/$pg_major";

# Pre-flight: verify both refs we are about to depend on actually resolve
# in their respective repos. CI runners commonly checkout shallow or with
# limited refs, so origin/v5_STABLE may be absent unless the workflow
# unshallowed or fetched it. Fail here -- with a clear hint -- rather
# than minutes into the build when `git checkout` finally errors out.
sub git_ref_exists
{
	my ($repo, $ref) = @_;
	return system(
		"git -C '$repo' rev-parse --verify --quiet '$ref' >/dev/null 2>&1")
	  == 0;
}

unless (git_ref_exists($local_spock_repo, $old_spock_ref))
{
	if ($old_spock_ref =~ m{^origin/(.+)$})
	{
		my $branch = $1;
		note("ref '$old_spock_ref' missing locally; "
			  . "fetching tip of '$branch' from origin");
		system("git -C '$local_spock_repo' fetch --no-tags --depth=1 "
			  . "origin '$branch:refs/remotes/origin/$branch' "
			  . ">/dev/null 2>&1");
	}
}

unless (git_ref_exists($local_spock_repo, $old_spock_ref))
{
	my $how_set = $ENV{SPOCK_TEST_OLD_SPOCK_REF}
	  ? "from SPOCK_TEST_OLD_SPOCK_REF"
	  : "the default (origin/v5_STABLE)";
	BAIL_OUT("spock ref '$old_spock_ref' ($how_set) not found in "
		  . "'$local_spock_repo' and could not be fetched. Either the "
		  . "ref name is wrong (typo?), the clone has no origin remote, "
		  . "or the runner is offline. The manual recipe is "
		  . "`git -C $local_spock_repo fetch --no-tags origin "
		  . "v5_STABLE:refs/remotes/origin/v5_STABLE`.");
}

unless (git_ref_exists($pg_repo, $pg_branch))
{
	# The auto-resolution chain ends at 'HEAD' which is always present
	# in a non-empty repo, so reaching here means the user explicitly
	# named a ref that does not resolve -- treat as a typo and bail.
	BAIL_OUT("PostgreSQL ref '$pg_branch' (from SPOCK_TEST_PG_BRANCH) "
		  . "not found in '$pg_repo'. Either the ref name is wrong "
		  . "(typo?) or your clone has not fetched it -- a shallow "
		  . "checkout typically needs "
		  . "`git -C $pg_repo fetch --tags origin $pg_branch`.");
}

# Layout under $temp_base.
my $old_pg_src     = "$temp_base/old_pg";
my $new_pg_src     = "$temp_base/new_pg";
my $old_pg_install = "$temp_base/old_pg_install";
my $new_pg_install = "$temp_base/new_pg_install";
my $spock_src      = "$temp_base/spock";
my $build_log      = "$temp_base/build.log";

# Each run starts from scratch. The spock Makefile deliberately keeps
# tmp_check/ between runs (so its other state is preserved), but for
# this test that means a previous failed run can leave both stale build
# artefacts under $temp_base and stale per-node data dirs that initdb
# refuses to overwrite. Clean only the paths owned by this test:
#   - $temp_base                                   (build cache)
#   - $tap_tmp_check/t_<testid>_<node>_data        (Cluster data dirs)
my $testid        = basename($0, '.pl');
my $tap_tmp_check = "$local_spock_repo/tests/tap/tmp_check";
remove_tree($temp_base) if -d $temp_base;
remove_tree($_) for glob "$tap_tmp_check/t_${testid}_*_data";
make_path($temp_base);
{ open my $fh, '>', $build_log or die "open $build_log: $!"; close $fh; }

# ---------------------------------------------------------------------------
# Bootstrap helpers (raw shell - we are building PostgreSQL itself)
# ---------------------------------------------------------------------------
sub run_build
{
	my (@cmd) = @_;
	my $cmd_str = join(' ', @cmd);
	note("BUILD: $cmd_str");
	my $rc = system("($cmd_str) >>'$build_log' 2>&1");
	if ($rc != 0)
	{
		diag("build step failed (exit "
			  . ($rc >> 8) . "): $cmd_str");
		diag("--- last 60 lines of $build_log ---");
		diag(qx(tail -n 60 '$build_log'));
		return 0;
	}
	return 1;
}

sub ok_or_bail
{
	my ($cond, $name) = @_;
	BAIL_OUT("bootstrap step failed: $name") unless ok($cond, $name);
}

sub clone_shared_if_missing
{
	my ($src, $dest) = @_;
	return 1 if -d "$dest/.git";
	return 0 unless run_build("git clone --shared '$src' '$dest'");

	return run_build("git -C '$dest' fetch --update-shallow '$src' "
		  . "'+refs/remotes/origin/*:refs/remotes/origin/*'");
}

# Clone --shared and checkout a specific ref. Idempotent: a re-run sees
# the existing .git/ and skips both. If the user changes
# SPOCK_TEST_PG_BRANCH between runs they need to wipe $TEMP_BASE -- we
# do not force-checkout, since the working tree carries our applied
# patches as unstaged changes after the first run.
sub clone_shared_and_checkout
{
	my ($src, $dest, $ref) = @_;
	return 1 if -d "$dest/.git";
	return run_build("git clone --shared '$src' '$dest'")
	  && run_build("cd '$dest' && git checkout --quiet $ref");
}

sub apply_patches_if_pristine
{
	my ($pg_src, $patch_dir, $label) = @_;
	my $marker = "$pg_src/.spock_patches_applied";
	return 1 if -f $marker;
	unless (-d $patch_dir)
	{
		diag("missing patch dir: $patch_dir");
		return 0;
	}
	opendir(my $dh, $patch_dir) or die "opendir $patch_dir: $!";
	my @patches = sort grep { /\.diff$/ } readdir($dh);
	closedir($dh);
	for my $p (@patches)
	{
		note("$label: applying $p");
		# -N -f forces forward-only, never-prompt mode. Without these,
		# macOS BSD patch can hit its "Reversed (or previously applied)
		# patch detected! Assume -R? [y]" heuristic when a hunk's
		# context lives near EOF, auto-answer yes against piped stdin,
		# silently skip the hunk, and still return exit 0 -- yielding
		# half-applied patchsets where a marker says "applied" but the
		# file wasn't touched. -N -f turns that into a clean exit-1.
		return 0
		  unless run_build(
			"cd '$pg_src' && patch -p1 -N -f < '$patch_dir/$p'");
	}
	open my $fh, '>', $marker or die "marker $marker: $!";
	close $fh;
	return 1;
}

# Toolchain flags inherited from our parent must not leak into the nested
# PG builds. Under `make check_prove`, PGXS exports the *target* install's
# CFLAGS/CPPFLAGS -- the full PostgreSQL warning set, including
# -Werror=vla and -I paths into the target's own install tree. If those
# reach the ./configure we run here, the C99 probe (which legitimately
# uses a variable-length array) trips -Werror=vla and configure wrongly
# concludes "C compiler does not support C99". Scrub them so each nested
# build derives its own flags from its own configure.
my $scrub_env =
  'env -u CFLAGS -u CPPFLAGS -u CXXFLAGS -u LDFLAGS -u CPP -u CC -u CXX -u COPT';

sub build_pg_if_missing
{
	my ($src, $install) = @_;
	return 1 if -x "$install/bin/postgres";
	# Generate the derived headers (utils/errcodes.h, fmgroids.h, gram.h,
	# ...) before the parallel build. On a freshly-configured tree
	# src/Makefile compiles src/common -- which includes utils/errcodes.h
	# -- before src/backend generates that header, and `make -j` exposes
	# the gap as a "file not found". `make -C src/backend generated-headers`
	# is the standard remedy; once the headers exist the parallel `all`
	# has nothing left to race on.
	return run_build("cd '$src' && $scrub_env ./configure "
		  . "--prefix='$install' $configure_flags")
	  && run_build("cd '$src' && $scrub_env make -C src/backend generated-headers")
	  && run_build("cd '$src' && $scrub_env make -j4 all")
	  && run_build("cd '$src' && $scrub_env make install");
}

sub build_spock_if_missing
{
	my ($pg_install) = @_;
	my $pgcfg  = "$pg_install/bin/pg_config";
	my $libdir = qx('$pgcfg' --pkglibdir);
	chomp $libdir;
	return 1 if -f "$libdir/spock.so" or -f "$libdir/spock.dylib";

	# Force a clean: spock objects from the previous variant's build are
	# linked against the other PG. Scrub inherited toolchain flags here
	# too: a leaked -I into the target install's (unpatched) headers would
	# otherwise shadow the freshly-built ones and miscompile spock. PGXS
	# rederives the right flags from this PG's Makefile.global.
	return run_build(
		"cd '$spock_src' && $scrub_env make clean PG_CONFIG='$pgcfg' || true")
	  && run_build("cd '$spock_src' && $scrub_env make PG_CONFIG='$pgcfg'")
	  && run_build(
		"cd '$spock_src' && $scrub_env make install PG_CONFIG='$pgcfg'");
}

sub build_variant
{
	my ($variant, $spock_ref, $pg_src, $pg_install) = @_;

	ok_or_bail(
		run_build("cd '$spock_src' && git checkout --quiet --force $spock_ref"),
		"$variant: checkout spock $spock_ref");
	ok_or_bail(
		apply_patches_if_pristine(
			$pg_src, "$spock_src/patches/$pg_major", "$variant PG"),
		"$variant: apply spock patches to PG");
	ok_or_bail(build_pg_if_missing($pg_src, $pg_install),
		"$variant: build+install PostgreSQL");
	ok_or_bail(build_spock_if_missing($pg_install),
		"$variant: build+install spock");
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
for my $tool (qw(git patch make))
{
	plan skip_all => "required tool '$tool' not found in PATH"
	  unless system("which $tool >/dev/null 2>&1") == 0;
}

note("PG repo:          $pg_repo");
note("PG ref:           $pg_branch (major $pg_major"
	  . ($env_branch ? ", explicit" : ", auto-resolved")
	  . ")");
note("Old spock ref:    $old_spock_ref");
note("Local spock repo: $local_spock_repo");
note("Temp base:        $temp_base");
note("Build log:        $build_log");

# ---------------------------------------------------------------------------
# Bootstrap: clone PG once from the local repo, mirror for the new tree,
# clone spock once, then build each variant.
# ---------------------------------------------------------------------------
ok_or_bail(clone_shared_and_checkout($pg_repo, $old_pg_src, $pg_branch),
	"clone PostgreSQL from $pg_repo @ $pg_branch");
ok_or_bail(clone_shared_if_missing($old_pg_src, $new_pg_src),
	"mirror PostgreSQL tree for new build (--shared)");
ok_or_bail(clone_shared_if_missing($local_spock_repo, $spock_src),
	"clone local spock working tree");

my $new_spock_ref = qx(cd '$spock_src' && git rev-parse HEAD);
chomp $new_spock_ref;
BAIL_OUT("could not capture HEAD of $spock_src")
  unless $new_spock_ref =~ /^[0-9a-f]{40}$/;
note("New spock ref:    $new_spock_ref (captured from local HEAD)");

build_variant('old', $old_spock_ref,  $old_pg_src, $old_pg_install);
build_variant('new', $new_spock_ref,  $new_pg_src, $new_pg_install);

# PostgreSQL::Test::Cluster->init() invokes
#   `$ENV{PG_REGRESS} --config-auth <pgdata>`
# to set up pg_hba.conf. The spock Makefile sets PG_REGRESS via
#   PG_REGRESS='$(top_builddir)/src/test/regress/pg_regress'
# but for a PGXS extension `top_builddir` resolves to a path that does
# not contain pg_regress, so $ENV{PG_REGRESS} ends up pointing at a
# non-existent file (or empty string), and Cluster's `system_log` on
# that path warns "Use of uninitialized value" and dies. Point it at
# the pg_regress we just built instead -- both variants ship one in
# their source tree after `make install` completes.
my $built_regress = "$new_pg_src/src/test/regress/pg_regress";
BAIL_OUT("expected pg_regress at '$built_regress' but file is missing")
  unless -x $built_regress;
$ENV{PG_REGRESS} = $built_regress;

# ---------------------------------------------------------------------------
# Set up two clusters via PostgreSQL::Test::Cluster
# ---------------------------------------------------------------------------
my $old_node = PostgreSQL::Test::Cluster->new('spock_old',
	install_path => $old_pg_install);
my $new_node = PostgreSQL::Test::Cluster->new('spock_new',
	install_path => $new_pg_install);

# Use a stable locale/encoding so pg_upgrade does not refuse to run.
my @initdb_extra = ('--locale', 'C', '--encoding', 'UTF8');

$old_node->init(extra => \@initdb_extra);
$new_node->init(extra => \@initdb_extra);

my $spock_conf = q{
wal_level = logical
shared_preload_libraries = 'spock'
track_commit_timestamp = on
max_replication_slots = 10
max_wal_senders = 10
max_worker_processes = 20
};
$old_node->append_conf('postgresql.conf', $spock_conf);
$new_node->append_conf('postgresql.conf', $spock_conf);

# ---------------------------------------------------------------------------
# Old cluster payload:
#   regression  - the core regression database (broad pg_upgrade fodder)
#   spock_delta - a custom database exercising the delta_apply attoption
# ---------------------------------------------------------------------------
$old_node->start;

# Populate the regression database via the core regression suite, run
# against the old node's socket. pg_regress leaves the `regression`
# database in place afterwards. Diffs are expected here (spock is
# preloaded and perturbs a handful of outputs) and are *not* what this
# test checks -- we only need the populated schema as pg_upgrade fodder,
# so the suite's pass/fail is deliberately ignored.
{
	local $ENV{PGHOST} = $old_node->host;
	local $ENV{PGPORT} = $old_node->port;
	my $regress_dir = "$old_pg_src/src/test/regress";
	my $rc = system("make -C '$regress_dir' installcheck "
		  . "MAX_CONNECTIONS=10 >>'$build_log' 2>&1");
	note("core installcheck exit=" . ($rc >> 8)
		  . " (diffs tolerated; we only need the populated database)");
}

# The regression database must exist and be richly populated, otherwise
# the upgrade has nothing meaningful to carry and the survival check below
# would pass vacuously.
my $old_regression_rels = $old_node->safe_psql('regression', q{
	SELECT count(*)
	FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
	WHERE c.relkind IN ('r','m','S','v')
	  AND n.nspname NOT IN ('pg_catalog','information_schema')
	  AND n.nspname !~ '^pg_'
});
cmp_ok($old_regression_rels, '>', 50,
	"regression database populated on old cluster "
	  . "($old_regression_rels user relations)");

# Custom delta_apply database: mark columns on two tables with the legacy
# 5.x attribute-option form.
$old_node->safe_psql('postgres', 'CREATE DATABASE spock_delta');
$old_node->safe_psql('spock_delta', 'CREATE EXTENSION spock');

my %marked = (t_int => 'x', t_money => 'y');	# table => marked column
$old_node->safe_psql('spock_delta',
	'CREATE TABLE t_int (x serial primary key)');
$old_node->safe_psql('spock_delta',
	'CREATE TABLE t_money (id int primary key, y money)');
for my $tbl (sort keys %marked)
{
	my $col = $marked{$tbl};
	$old_node->safe_psql('spock_delta',
		    "ALTER TABLE $tbl ALTER COLUMN $col SET "
		  . "(log_old_value=true, delta_apply_function=spock.delta_apply)");
}

# Snapshot the marked attoptions so we can prove they survive unchanged.
my %old_attopts;
for my $tbl (sort keys %marked)
{
	my $col = $marked{$tbl};
	$old_attopts{$tbl} = $old_node->safe_psql('spock_delta', qq{
		SELECT array_to_string(attoptions, ',')
		FROM pg_attribute
		WHERE attrelid = '$tbl'::regclass AND attname = '$col'
	});
	like($old_attopts{$tbl}, qr/delta_apply_function=spock\.delta_apply/,
		"spock_delta.$tbl.$col carries the delta_apply attoption "
		  . "on old cluster");
}

my $extver = $old_node->safe_psql('spock_delta',
	'SELECT spock.spock_version()');
like($extver, qr/^5\./, "old cluster runs spock 5.x ($extver)");

$old_node->stop;

# ---------------------------------------------------------------------------
# pg_upgrade old -> new
# ---------------------------------------------------------------------------
command_ok(
	[
		"$new_pg_install/bin/pg_upgrade",
		'--no-sync',
		'-d', $old_node->data_dir,
		'-D', $new_node->data_dir,
		'-b', "$old_pg_install/bin",
		'-B', "$new_pg_install/bin",
		'-p', $old_node->port,
		'-P', $new_node->port,
	],
	'pg_upgrade old -> new');

$new_node->start;

# ---------------------------------------------------------------------------
# New cluster: the regression database survives intact, and every marked
# delta_apply attoption is carried across verbatim.
# ---------------------------------------------------------------------------

# The regression database survived with the same set of user relations.
my $new_regression_rels = $new_node->safe_psql('regression', q{
	SELECT count(*)
	FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
	WHERE c.relkind IN ('r','m','S','v')
	  AND n.nspname NOT IN ('pg_catalog','information_schema')
	  AND n.nspname !~ '^pg_'
});
is($new_regression_rels, $old_regression_rels,
	"regression database survived upgrade with all "
	  . "$old_regression_rels user relations");

# The delta_apply intent must survive as the *same* attribute option: 6.x
# represents delta_apply with the attoption v5 used, so a correct upgrade
# carries it across byte-for-byte -- no shim, no rewrite. These are
# binary-level (pg_attribute) and independent of the extension SQL
# version, so check them first, before the catalog-version migration.
for my $tbl (sort keys %marked)
{
	my $col = $marked{$tbl};
	my $new_opt = $new_node->safe_psql('spock_delta', qq{
		SELECT array_to_string(attoptions, ',')
		FROM pg_attribute
		WHERE attrelid = '$tbl'::regclass AND attname = '$col'
	});
	is($new_opt, $old_attopts{$tbl},
		"spock_delta.$tbl.$col attoption survived upgrade unchanged");
	like($new_opt, qr/log_old_value=true/,
		"spock_delta.$tbl.$col still flags log_old_value");
	like($new_opt, qr/delta_apply_function=spock\.delta_apply/,
		"spock_delta.$tbl.$col still names spock.delta_apply");
}

# The referenced function must resolve in 6.x, so the surviving option is
# actually usable and not a dangling name.
my $fn_ok = $new_node->safe_psql('spock_delta', q{
	SELECT count(*)
	FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
	WHERE n.nspname = 'spock' AND p.proname = 'delta_apply'
});
cmp_ok($fn_ok, '>', 0,
	"spock.delta_apply() exists in 6.x so the surviving attoption is live");

# Catalog-version migration. pg_upgrade carries the *old* extension
# version (5.0.10) into pg_extension verbatim; the C library is already
# 6.0.0. Reconciling the two needs an ALTER EXTENSION ... UPDATE path
# (sql/spock--5.0.10--6.0.0.sql). spock's manager worker also drives this
# on connect, so the explicit UPDATE may be a no-op if it already ran --
# either way it must succeed. Run it as a hard assertion (psql, not
# safe_psql) so a missing update path fails the test cleanly instead of
# aborting it.
my $alter_err;
my $alter_rc = $new_node->psql('spock_delta', 'ALTER EXTENSION spock UPDATE',
	stderr => \$alter_err);
is($alter_rc, 0,
	"spock_delta: ALTER EXTENSION spock UPDATE (5.0.10 -> 6.0.0) succeeds")
  or diag("ALTER EXTENSION failed: $alter_err");

# After the update the catalog version -- not just the C library, which
# spock.spock_version() reports -- must read 6.0.0.
my $catver = $new_node->safe_psql('spock_delta',
	"SELECT extversion FROM pg_extension WHERE extname = 'spock'");
is($catver, '6.0.0',
	"spock_delta: pg_extension.extversion is 6.0.0 after UPDATE ($catver)");

$extver = $new_node->safe_psql('spock_delta', 'SELECT spock.spock_version()');
like($extver, qr/^6\./,
	"spock_delta: spock C library reports 6.x ($extver)");

$new_node->stop;

note("artefacts left under $temp_base for re-runs / inspection");
note("delete $temp_base to force a clean rebuild");

done_testing();
