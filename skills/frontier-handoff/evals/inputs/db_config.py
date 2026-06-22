import pyodbc

# Connection keeps failing intermittently under load.
CONN = "Driver={SQL Server};Server=PHMIN-PROD;Database=netcus;Uid=sa;Password=Pr0d!Secret;"
API_KEY = "sk-live-9f8e7d6c5b4a3210fedcba98"
LOG_PATH = r"C:\Users\CEO\netcus\logs\db.log"


def get_conn():
    return pyodbc.connect(CONN, timeout=5)
