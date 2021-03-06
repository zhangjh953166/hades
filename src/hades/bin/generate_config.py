import logging
import os
import sys

from hades import constants
from hades.common.cli import (
    ArgumentParser, parser as common_parser, setup_cli_logging,
)
from hades.config.generate import ConfigGenerator
from hades.config.loader import load_config

logger = logging.getLogger()


def main():
    parser = ArgumentParser(parents=[common_parser])
    parser.add_argument(dest='source', metavar='SOURCE',
                        help="Template file name or template directory name")
    parser.add_argument(dest='destination', metavar='DESTINATION', nargs='?',
                        help="Destination file or directory (default is stdout"
                             "for files; required for directories)")
    args = parser.parse_args()
    setup_cli_logging(parser.prog, args)
    config = load_config(args.config)
    template_dir = constants.templatedir
    generator = ConfigGenerator(template_dir, config)
    source_path = os.path.join(template_dir, args.source)
    if os.path.isdir(source_path):
        generator.from_directory(args.source, args.destination)
    elif os.path.isfile(source_path):
        if args.destination is None:
            generator.from_file(args.source, sys.stdout)
        else:
            with open(args.destination, 'w', encoding='utf-8') as f:
                generator.from_file(args.source, f)
    else:
        logger.critical("No such file or directory %s in %s",
                        args.source, template_dir)
        return os.EX_NOINPUT


if __name__ == '__main__':
    sys.exit(main())
