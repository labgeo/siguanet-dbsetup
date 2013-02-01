# -*- coding: utf-8 -*-
import os
import gettext
import getpass
import psycopg2
import sys
from argparse import ArgumentParser
from mako.template import Template

EXEC_DIR = os.path.dirname(__file__)
DEFAULT_SQLSCRIPT_PATH = os.path.join(EXEC_DIR, "siguanet-dbsetup.sql")

#i18n
LOCALE_DIR = os.path.join(EXEC_DIR, "locale")
translation = gettext.translation("siguanet-dbsetup", localedir=LOCALE_DIR,
                                  fallback=True)
_ = translation.gettext

#l10n
srid_help = _("Spatial reference system EPSG identifier")
aboveground_help = _("Max. number of aboveground floors")
underground_help = _("Max. number of underground floors")
output_help = _("Output SQL script file name")
server_help = _("PostgreSQL server address")
database_help = _("PostgreSQL database name (PostGIS 2.0 extension required)")
port_help = _("PostgreSQL server port")
username_help = _("PostgreSQL user name")
database_required = _("No database name provided. Use -d [DATABASE] option")
username_required = _("No user name provided. Use -u [USERNAME] option")
password_prompt = _("Password for user {0}: ")
sqlscript_created = _("{0} successfully created")
pgsql9_required = _("PostgreSQL server version 9.1 or above is required")
postgis2_required = _("PostGIS 2 extension not found in database {0}")
connection_closed = _("Database connection closed")
success_msg = _("Process ended successfully!")


class FloorBuilder:

    def GetNames(self, aboveground, underground):
        names = ["sigpb"]
        for i in range(1, abs(int(aboveground)) + 1):
            names.append("sigp{0}".format(i))
        for i in range(1, abs(int(underground)) + 1):
            names.append("sigs{0}".format(i))
        return names


class CnStringBuilder:

    def GetCnString(self, database, host=None, port=None, username=None):
        if not host:
            host = "localhost"
        if not port:
            port = 5432
        if not database:
            raise TypeError(database_required)
        if not username:
            username = getpass.getuser()
        password = getpass.getpass(password_prompt.format(username))
        cnstr = "host={0} port={1} dbname ={2} user={3} password={4}"
        return cnstr.format(host, port, database, username, password)


class PostGISInfo:

    def __init__(self, connection):
        self.cn = connection

    def IsPgsql9(self):
        cur = self.cn.cursor()
        cur.execute("select version() like 'PostgreSQL 9%'")
        r = cur.fetchone()
        cur.close()
        return r

    def IsPostGIS2(self):
        cur = self.cn.cursor()
        cur.execute("select exists (select 1 from pg_catalog.pg_extension"
                    " where extname = 'postgis'"
                    " and left(extversion, 1) = '2')")
        r = cur.fetchone()
        cur.close()
        return r


class SQLScriptFile:

    def __init__(self, connection):
        self.cn = connection

    def Execute(self, filepath=None):
        with open(filepath, 'r') as src:
            cursor = self.cn.cursor()
            cursor.execute(src.read())
            cursor.close()


def main():

    py3k = sys.version_info >= (3, 0)

    parser = ArgumentParser()
    parser.add_argument("srid", type=int, help=srid_help)
    parser.add_argument("aboveground", type=int, help=aboveground_help)
    parser.add_argument("underground", type=int, help=underground_help)
    parser.add_argument("-o", "--output", default=DEFAULT_SQLSCRIPT_PATH,
                        help=output_help)
    parser.add_argument("-s", "--server", help=server_help)
    parser.add_argument("-d", "--database", help=database_help)
    parser.add_argument("-p", "--port", type=int, help=port_help)
    parser.add_argument("-u", "--username", help=username_help)
    args = parser.parse_args()

    cn = None

    fbuilder = FloorBuilder()
    floors = fbuilder.GetNames(args.aboveground, args.underground)
    sql_template = Template(filename="siguanet-dbsetup.mako")
    sql_source = sql_template.render_unicode(referencia_espacial=args.srid,
                                             plantas=floors)
    with open(args.output, 'w') as out_sqlscript:
        if py3k:
            out_sqlscript.write(sql_source)
        else:
            out_sqlscript.write(sql_source.encode("utf8"))

    sqlscript = os.path.abspath(args.output)
    print((sqlscript_created.format(sqlscript)))

    if args.database:
        try:
            dsnbuilder = CnStringBuilder()
            cnstr = dsnbuilder.GetCnString(args.database, host=args.server,
                                           port=args.port,
                                           username=args.username)
            cn = psycopg2.connect(cnstr)
            geos = PostGISInfo(cn)
            isver = geos.IsPgsql9()[0]
            if isver:
                isver = geos.IsPostGIS2()[0]
                if isver:
                    sql = SQLScriptFile(cn)
                    sql.Execute(sqlscript)
                    cn.commit()
                else:
                    print((postgis2_required.format(args.database)))
            else:
                print(pgsql9_required)
        except Exception as e:
            print(e)
            sys.exit(1)
        finally:
            if cn:
                cn.close()
                print(connection_closed)

    print(success_msg)

if __name__ == "__main__":
    main()