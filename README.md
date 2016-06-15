Endless OSTree Builder (EOB)
============================

This program assembles the Endless OS (EOS) from prebuilt packages and
content. Its main functions are:
 1. Assemble packages into ostree
 2. Publish the ostree repo to a remote server

Design
======

EOB is designed to be simple. It is written in bash script and has just
enough flexibility to meet our needs. The simplicity allows us to have a
complete in-house understanding of the build system, enabling smooth
organic growth as our requirements evolve. The build master(s) who
maintain this system are not afraid of encoding our requirements in
simple bash script.

When added complexity is minimal, we prefer calling into lower level
tools directly rather than utilizing abstraction layers (e.g. we call
debootstrap instead of using live-tools). This means we have a thorough
understanding of the build system and helps to achieve our secondary
goals of speed and flexibility.

The build process is divided into several stages, detailed below. An
invocation can run some or all of these stages.

check_update stage
------------------

This stage does not perform ostree building, but is used to determine if
an ostree build is required. If it exits successfully, no ostree build
is needed.

OS stage
--------

This stage creates the OS in a clean directory tree, populating it with
apt packages.

ostree stage
------------

This stage makes appropriate modifications to the output of the previous
stage and commits it to a locally stored ostree repository. The ostree
repository is created if it does not already exist.

publish stage
-------------

This stage publishes the local ostree repository to the remote ostree
server.

error stage
-----------

This stage is only run in the event of an error and simply cleans up for
a subsequent build.

Setup
=====

Known to work on Debian Wheezy, Ubuntu 13.04 and Ubuntu 13.10.
Required packages:
 * rsync
 * ostree
 * python3-apt
 * attr
 * x86: grub2
 * arm: mkimage, device-tree-compiler

ostree signing
--------------

EOB signs the ostree commits it makes with GPG. A private keyring must
be installed in /etc/deb-ostree-builder/gnupg and the key ID must be set
in the configuration.

Configuration
=============

The ostree builder configuration is built up from a series of INI files.
The configuration files are stored in the `config` directory of the
builder. The order of configuration files read in is:

  * Default settings - `config/defaults.ini`
  * Product settings - `config/product/$product.ini`
  * Branch settings - `config/branch/$branch.ini`
  * Architecture settings - `config/arch/$arch.ini`
  * Platform settings - `config/platform/$platform.ini`
  * System config settings - `/etc/deb-ostree-builder/config.ini`
  * Local build settings - `config/local.ini`

None of these files are required to be present, but the `defaults.ini`
file contains many settings that are expected throughout the core of the
build.

New configuration options should be added and documented in
`defaults.ini`. See the existing file for options that are available to
customize. Settings in the default `build` section are usually set in
the `OSTreeBuilder` class as they're static across all builds.

Format
------

The format of the configuration files is INI as mentioned above.
However, a form of interpolation is used to allow referring to other
options. For instance, an option `foo` can use the value from an option
`bar` by using `${bar}` in its value. If `bar` was in a different
section, it can be referred to by prepending the other section in the
form of `${other:bar}`. The `build` section is the default section. Any
interpolation without an explicit section can fallback to a value in the
`build` section. For example, if `bar` doesn't exist in the current
section, it will also be looked for in the `build` section.

The INI file parsing is done using the `configparser` `python` module.
The interpolation feature is provided by its `ExtendedInterpolation`
class. See the `python`
[documentation](https://docs.python.org/3/library/configparser.html#configparser.ExtendedInterpolation)
for a more detailed discussion of this feature.

The system and local configuration files are not typically used. They
can allow for a permanent or temporary override for a particular host or
build.

Merged options
--------------

In some cases, an option needs to represent a set of values rather than
a single setting. Adding or removing items from the list is not possible
with the features in the configuration parser.

To allow some method of building these lists, the builder will take
multiple options of the form `$prefix_add_*` and `$prefix_del_*` and
merge them together into one option named `$prefix`. Values in the
various `$prefix_add_*` options are added to a set, and then values in
the various `$prefix_del_*` options are removed from the set. If the
option `$prefix` already exists, it is not changed. This allows a
configuration file to override all of the various `add` and `del`
options from other files to provide the list exactly in the form it
wants.

The currently supported merged options are:

* `cache:hooks`
* `seed:hooks`
* `os:hooks`
* `os:packages`
* `ostree:extra_refs`
* `publish:hooks`
* `error:hooks`

See the `defaults.ini` file for a description of these options.

Accessing options
-----------------

The build core accesses these settings via environment variables. The
variables take the form of `EOB_$SECTION_$OPTION`. The `build` section
is special and these settings are exported in the form `EOB_$OPTION`
without the section in the variable name.

Execution
=========

To run EOB, use the deb-ostree-builder script, optionally with a branch name:
 # ./deb-ostree-builder [options] master

If no branch name is specified, master is used. If you want to only run
certain stages, modify the `buildscript` file accordingly before
starting the program.

Options available:
  --product : specify product to build (debian, debianplatform, debiansdk)
  --arch : specify architecture to build (i386, armhf)
  --platform : specify a sub-architecture to build
  --force : perform a build even if the update check says it's not needed
  --dry-run : perform a build, but do not publish the results

Customization
=============

The core of EOB is just a wrapper. The real content of the output is
defined by customization scripts found under hooks/. These scripts have
access to environment variables and library functions allowing them to
integrate correctly with the core.

The scripts to run are organized under `hooks/GROUP` where `GROUP` is a
group of hooks run by a particular stage. The hooks to run are managed
in the configuration with merged `hooks` keys under each group. For
instance, the `os` group hooks to run are defined in the `os:hooks`
configuration key. This allows easy customization for different OS
variants. These are merged options as described above, so they can be
added to or pruned by specific products.

If a script has an executable bit, it is executed directly. Otherwise it
is executed through bash and will have access to the library functions.

If a script filename finishes with ".chroot" then it is executed within
the chroot environment, as if it is running on the final system.
Otherwise, the script is executed under the regular host environment. It
is preferred to avoid chrooted scripts when it is easy to run the
operation outside of the chroot environment.

Scripts are executed in lexical order and the convention is to prefix
them with a two-digit number to make the order explicit. Each script
should be succinct - we prefer to have a decent number of small-ish
scripts, rather than having a small number of huge bash rambles.

check_update customization
--------------------------

The check_update stage calls the `cache` customization hooks. The
intention is to determine facts about the current build and compare them
to cached facts from the previous build. Facts are stored in the build
specific cache directory, determined from the function `eob_cachedir`.
Cache files should be named using the eob_cachefile function.

The check_update stage determines if an update is needed by seeing if
the modification times for any files in the cache directory have been
updated. Therefore, the hook should only update its cache file if
there's a difference from the previous build.

os customization
----------------

At the start of the os stage, the customization hooks under `seed` are
run. At this stage the `${EOB_ROOTDIR}` is totally empty. Place
anything here that you want to be present at the time of initial
bootstrap, which follows.

After the initial bootstrap, the customization hooks under `os` are run.
These scripts are responsible for making any configuration changes to
the system (discouraged), installing packages, etc. The OS packages are
installed by scripts at index 50.

ostree customization
--------------------

The ostree stage currently has no customization hooks.

publish customization
---------------------

Keeping with the design that the core is simple and the meat is kept
under customization, the publish stage does nothing more than call into
customization hooks kept in `publish`. This stage should publish the
local ostree repo to the remote server.

error customization
---------------------

Like the publish stage, the error stage simply calls the customization
hooks kept in `error`. These hooks should clean up for subsequent
builds.
