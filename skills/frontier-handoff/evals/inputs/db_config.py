import pyodbc

# Connection keeps failing intermittently under load. The connection string is built elsewhere from an
# untracked settings file (no credentials in this file).


def get_conn(conn_string):
    return pyodbc.connect(conn_string, timeout=5)
