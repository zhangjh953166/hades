import grp
import logging
import os
import pwd
import sys

from hades.common.cli import (
    ArgumentParser, parser as common_parser, setup_cli_logging,
)

logger = logging.getLogger(__name__)


def drop_privileges(passwd, group):
    os.setgid(group.gr_gid)
    os.initgroups(passwd.pw_name, group.gr_gid)
    os.setuid(passwd.pw_uid)


def main():
    parser = ArgumentParser(parents=[common_parser])
    parser.add_argument('user')
    parser.add_argument('command')
    parser.add_argument('arguments', nargs='*')
    args = parser.parse_args()
    setup_cli_logging(parser.prog, args)
    try:
        passwd = pwd.getpwnam(args.user)
        group = grp.getgrgid(passwd.pw_gid)
    except KeyError:
        logger.critical("No such user or group")
        return os.EX_NOUSER
    filename = args.command
    try:
        drop_privileges(passwd, group)
    except PermissionError:
        logging.exception("Can't drop privileges")
        return os.EX_NOPERM
    try:
        os.execvp(filename, [filename] + args.arguments)
    except (FileNotFoundError, PermissionError):
        logger.critical("Could not execute %s", filename)
        return os.EX_NOINPUT
    except OSError:
        logger.exception("An OSError occurred")
        return os.EX_OSERR


if __name__ == '__main__':
    sys.exit(main())
