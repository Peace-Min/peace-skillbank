import json


def load_config(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


if __name__ == "__main__":
    cfg = load_config("vendor_config.json")
    print(cfg["version"])
