# -*- mode: Python; coding: utf-8 -*-

# Endless ostree builder library
#
# Copyright (C) 2015  Endless Mobile, Inc.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

from argparse import ArgumentParser
import configparser
import fnmatch
import os
import shutil

BUILDDIR = '/var/cache/deb-ostree-builder'
SYSCONFDIR = '/etc/deb-ostree-builder'
LOCKFILE = '/var/lock/deb-ostree-builder.lock'
LOCKTIMEOUT = 60

class OSTreeBuildError(Exception):
    """Errors from the ostree builder"""
    def __init__(self, *args):
        self.msg = ' '.join(map(str, args))

    def __str__(self):
        return str(self.msg)

class OSTreeConfigParser(configparser.ConfigParser):
    """Configuration parser for the ostree builder. This uses configparser's
    ExtendedInterpolation to expand values like variables."""

    defaultsect = 'build'

    def __init__(self, *args, **kwargs):
        kwargs['interpolation'] = configparser.ExtendedInterpolation()
        kwargs['default_section'] = self.defaultsect
        super().__init__(*args, **kwargs)

    def items_no_default(self, section, raw=False):
        """Return the items in a section without including defaults"""
        # This is a nasty hack to overcome the behavior of the normal
        # items(). The default section needs to be merged in to resolve
        # the interpolation, but we only want the keys from the section
        # itself.
        d = self.defaults().copy()
        sect = self._sections[section]
        d.update(sect)
        if raw:
            value_getter = lambda option: d[option]
        else:
            value_getter = \
                lambda option: self._interpolation.before_get(self,
                                                              section,
                                                              option,
                                                              d[option],
                                                              d)
        return [(option, value_getter(option)) for option in sect.keys()]

    def setboolean(self, section, option, value):
        """Convenience method to store boolean's in shell style
        true/false
        """
        assert(isinstance(value, bool))
        if value:
            value = 'true'
        else:
            value = 'false'
        self.set(section, option, value)

    def merge_option_prefix(self, section, prefix):
        """Merge multiple options named like <prefix>_add_* and
        <prefix>_del_*. The original options will be deleted.
        If an option named <prefix> already exists, it is not changed.
        """
        sect = self[section]
        add_opts = fnmatch.filter(sect.keys(), prefix + '_add_*')
        del_opts = fnmatch.filter(sect.keys(), prefix + '_del_*')

        # If the prefix doesn't exist, merge together the add and del
        # options and set it.
        if prefix not in sect:
            add_vals = set()
            for opt in add_opts:
                add_vals.update(sect[opt].split())
            del_vals = set()
            for opt in del_opts:
                del_vals.update(sect[opt].split())

            # Set the prefix to the difference of the sets. Merge
            # the values together with newlines like they were in
            # the original configuration.
            sect[prefix] = '\n'.join(sorted(add_vals - del_vals))

        # Remove the add/del options to cleanup the section
        for opt in add_opts + del_opts:
            del sect[opt]

def recreate_dir(path):
    """Delete and recreate a directory"""
    shutil.rmtree(path, ignore_errors=True)
    os.makedirs(path, exist_ok=True)

def add_cli_options(argparser):
    """Add command line options for deb-ostree-builder. This allows the
    settings to be shared between deb-ostree-builder and run-build.
    """
    assert(isinstance(argparser, ArgumentParser))
    argparser.add_argument('-p', '--product', default='debian',
                           help='product to build')
    argparser.add_argument('-a', '--arch', help='architecture to build')
    argparser.add_argument('-P', '--platform', help='platform to build')
    argparser.add_argument('--show-config', action='store_true',
                           help='show configuration and exit')
    argparser.add_argument('-f', '--force', action='store_true',
                           help='run build even when no new assets found')
    argparser.add_argument('-n', '--dry-run', action='store_true',
                           help="don't publish images")
    argparser.add_argument('--no-checkout', action='store_true',
                           help='use current builder branch')
    argparser.add_argument('--lock-timeout', type=int, default=LOCKTIMEOUT,
                           help='time in seconds to acquire lock before exiting')
    argparser.add_argument('branch', nargs='?', default='unstable',
                           help='branch to build')
