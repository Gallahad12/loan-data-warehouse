"""Generate synthetic loan data for a fictional Indonesian multifinance company.

Everything is random but reproducible (fixed seed). Outputs:
  source/loancore_seed.sql      LoanCore OLTP state as of 2025-12-31
  source/loancore_changes.sql   Changes made in January 2026 (new loans, customer moves)
  data/incoming/payments_YYYYMM.csv     Monthly payment gateway files up to 2025-12
  data/next_month/payments_202601.csv   The January 2026 file, for the incremental demo

Usage: python scripts/generate_data.py
"""
import calendar
import csv
import random
from datetime import date, datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SEED = 42
N_CUSTOMERS = 5_000
N_LOANS = 8_000
FIRST_APPLICATION = date(2023, 1, 1)
LAST_APPLICATION = date(2026, 1, 25)
SEED_CUTOFF = date(2025, 12, 31)  # OLTP snapshot date for the initial load
PAYMENTS_END = date(2026, 1, 31)  # No payments after this date

rng = random.Random(SEED)

BRANCHES = [
    # branch_id, city, province, region, weight
    ("JKT01", "Jakarta Selatan", "DKI Jakarta", "Jawa", 12),
    ("JKT02", "Jakarta Timur", "DKI Jakarta", "Jawa", 10),
    ("BKS01", "Bekasi", "Jawa Barat", "Jawa", 9),
    ("BDG01", "Bandung", "Jawa Barat", "Jawa", 9),
    ("SMG01", "Semarang", "Jawa Tengah", "Jawa", 7),
    ("YOG01", "Yogyakarta", "DI Yogyakarta", "Jawa", 6),
    ("SBY01", "Surabaya", "Jawa Timur", "Jawa", 10),
    ("MDN01", "Medan", "Sumatera Utara", "Sumatera", 8),
    ("PLG01", "Palembang", "Sumatera Selatan", "Sumatera", 6),
    ("BPN01", "Balikpapan", "Kalimantan Timur", "Kalimantan", 5),
    ("MKS01", "Makassar", "Sulawesi Selatan", "Sulawesi", 7),
    ("DPS01", "Denpasar", "Bali", "Bali & Nusa Tenggara", 5),
]

PRODUCTS = [
    # product_id, name, category, annual flat rate, tenors, min/max principal, weight
    ("P01", "Kredit Motor Baru", "Kendaraan", 0.20, [12, 24, 36], 15_000_000, 35_000_000, 35),
    ("P02", "Kredit Mobil Bekas", "Kendaraan", 0.14, [24, 36, 48], 80_000_000, 250_000_000, 10),
    ("P03", "Kredit Multiguna", "Multiguna", 0.22, [12, 24, 36], 10_000_000, 100_000_000, 20),
    ("P04", "Kredit Elektronik", "Konsumtif", 0.30, [6, 12], 3_000_000, 15_000_000, 20),
    ("P05", "Modal Usaha Mikro", "Produktif", 0.24, [12, 24], 10_000_000, 75_000_000, 15),
]

OCCUPATIONS = [
    # name, min/max monthly income, weight
    ("Karyawan Swasta", 4_500_000, 15_000_000, 30),
    ("Wiraswasta", 3_500_000, 25_000_000, 15),
    ("PNS", 5_000_000, 12_000_000, 8),
    ("Pedagang", 3_000_000, 12_000_000, 12),
    ("Pengemudi Ojek Online", 3_000_000, 7_000_000, 10),
    ("Guru", 3_500_000, 9_000_000, 6),
    ("Buruh Pabrik", 3_000_000, 6_000_000, 10),
    ("Petani", 2_500_000, 6_000_000, 4),
    ("Tenaga Kesehatan", 5_000_000, 14_000_000, 5),
]

MALE = ["Budi", "Agus", "Andi", "Rizky", "Dimas", "Fajar", "Hendra", "Joko", "Bayu", "Arief",
        "Yoga", "Eko", "Teguh", "Wahyu", "Ilham", "Reza", "Bagus", "Dani", "Fikri", "Gilang"]
FEMALE = ["Siti", "Dewi", "Putri", "Ayu", "Rina", "Wulan", "Indah", "Lestari", "Fitri", "Nurul",
          "Sri", "Maya", "Ratna", "Intan", "Dian", "Novi", "Tika", "Yuni", "Anisa", "Citra"]
SURNAMES = ["Saputra", "Wijaya", "Pratama", "Santoso", "Hidayat", "Kusuma", "Nugroho", "Siregar",
            "Nasution", "Simanjuntak", "Setiawan", "Gunawan", "Halim", "Rahman", "Lubis", "Harahap",
            "Wibowo", "Purnomo", "Susanto", "Tanjung", "Sembiring", "Ginting", "Manurung",
            "Kurniawan", "Firmansyah", "Ramadhan", "Hasibuan", "Utami", "Permata", "Maharani"]

CHANNELS = [("Virtual Account", 45), ("Mobile Banking", 25), ("Minimarket", 20), ("Teller Cabang", 10)]


def pick(items, weight_index):
    return rng.choices(items, weights=[i[weight_index] for i in items])[0]


def add_months(d: date, n: int) -> date:
    """Same rule as T-SQL DATEADD(month, n, d): clamp to the last day of the month."""
    month = d.month - 1 + n
    year = d.year + month // 12
    month = month % 12 + 1
    return date(year, month, min(d.day, calendar.monthrange(year, month)[1]))


def random_date(start: date, end: date) -> date:
    return start + timedelta(days=rng.randint(0, (end - start).days))


def round_to(value: float, step: int) -> int:
    return int(round(value / step) * step)


def sql_value(v) -> str:
    if v is None:
        return "NULL"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, datetime):
        return f"'{v:%Y-%m-%d %H:%M:%S}'"
    if isinstance(v, date):
        return f"'{v:%Y-%m-%d}'"
    return "N'" + str(v).replace("'", "''") + "'"


def insert_statements(table: str, columns: list[str], rows: list[tuple], batch: int = 500) -> str:
    out = []
    for i in range(0, len(rows), batch):
        values = ",\n".join("(" + ", ".join(sql_value(v) for v in row) + ")" for row in rows[i:i + batch])
        out.append(f"INSERT INTO {table} ({', '.join(columns)}) VALUES\n{values};\n")
    return "".join(out)


def random_time(d: date) -> datetime:
    return datetime(d.year, d.month, d.day, rng.randint(8, 20), rng.randint(0, 59), rng.randint(0, 59))


# ---------------------------------------------------------------- customers
def make_customer(i: int, branch) -> dict:
    gender = rng.choice("LP")
    first = rng.choice(MALE if gender == "L" else FEMALE)
    occupation = pick(OCCUPATIONS, 3)
    income = round_to(rng.uniform(occupation[1], occupation[2]), 100_000)
    # Lower income and some jobs carry more risk. This hidden grade drives payment behaviour.
    bad_share = 0.05 + (0.05 if income < 4_500_000 else 0) + (0.03 if occupation[0] == "Pengemudi Ojek Online" else 0)
    late_share = 0.16
    roll = rng.random()
    risk = "bad" if roll < bad_share else "late" if roll < bad_share + late_share else "good"
    return {
        "customer_id": f"CUS{i:06d}",
        "full_name": f"{first} {rng.choice(SURNAMES)}",
        "gender": gender,
        "birth_date": random_date(date(1965, 1, 1), date(2004, 12, 31)),
        "occupation": occupation[0],
        "monthly_income": income,
        "branch": branch,
        "city": branch[1],
        "province": branch[2],
        "risk": risk,
        "loans": [],
    }


customers = [make_customer(i + 1, pick(BRANCHES, 4)) for i in range(N_CUSTOMERS)]

# -------------------------------------------------------------------- loans
loans = []
for i in range(N_LOANS):
    customer = rng.choice(customers)
    product = pick(PRODUCTS, 7)
    tenor = rng.choice(product[4])
    rate = product[3]
    principal = round_to(rng.uniform(product[5], product[6]), 500_000)
    # Keep the installment within 40% of income, as a lender would.
    max_principal = 0.40 * customer["monthly_income"] * tenor / (1 + rate * tenor / 12)
    principal = max(product[5], min(principal, round_to(max_principal, 500_000)))
    installment = round_to((principal + principal * rate * tenor / 12) / tenor, 100)
    application = random_date(FIRST_APPLICATION, LAST_APPLICATION)
    disbursement = application + timedelta(days=rng.randint(1, 6))
    loan = {
        "loan_id": f"LN{i + 1:07d}",
        "customer": customer,
        "branch_id": customer["branch"][0],
        "product_id": product[0],
        "application_date": application,
        "disbursement_date": disbursement,
        "principal_amount": principal,
        "interest_rate_flat": rate,
        "tenor_months": tenor,
        "installment_amount": installment,
    }
    customer["loans"].append(loan)
    loans.append(loan)

for c in customers:
    first_application = min((l["application_date"] for l in c["loans"]), default=random_date(FIRST_APPLICATION, LAST_APPLICATION))
    c["created_at"] = random_time(max(date(2022, 6, 1), first_application - timedelta(days=rng.randint(1, 120))))
    if c["created_at"].date() > SEED_CUTOFF and any(l["application_date"] <= SEED_CUTOFF for l in c["loans"]):
        c["created_at"] = random_time(SEED_CUTOFF)
    c["updated_at"] = c["created_at"]
for l in loans:
    l["created_at"] = random_time(l["application_date"])
    l["updated_at"] = random_time(l["disbursement_date"])

# ----------------------------------------------------------------- payments
payments = []
payment_seq = 0
for loan in loans:
    risk = loan["customer"]["risk"]
    stop_after = rng.randint(1, loan["tenor_months"] - 1) if risk == "bad" else None
    previous = loan["disbursement_date"]
    for n in range(1, loan["tenor_months"] + 1):
        if stop_after is not None and n > stop_after:
            break
        due = add_months(loan["disbursement_date"], n)
        if risk == "good":
            delay = rng.randint(1, 10) if rng.random() < 0.08 else -rng.randint(0, 5)
        else:
            delay = rng.randint(46, 130) if rng.random() < 0.12 else rng.randint(1, 45)
        paid = max(due + timedelta(days=delay), previous)
        if paid > PAYMENTS_END:
            break
        previous = paid
        payment_seq += 1
        payments.append({
            "payment_id": f"TRX{payment_seq:09d}",
            "loan_id": loan["loan_id"],
            "installment_no": n,
            "payment_date": paid.isoformat(),
            "amount": str(loan["installment_amount"]),
            "channel": pick(CHANNELS, 1)[0],
        })

# Real gateway files are not clean. Corrupt a few rows so the SSIS error handling has work to do.
rng.shuffle(payments)
dirty = {"amount_format": 0, "invalid_date": 0, "unknown_loan": 0, "duplicate": 0}
extra = []
for p in payments[:int(len(payments) * 0.004)]:
    kind = rng.choice(list(dirty))
    dirty[kind] += 1
    if kind == "amount_format":
        p["amount"] = "Rp" + f"{int(p['amount']):,}".replace(",", ".")  # Rp1.250.000 style
    elif kind == "invalid_date":
        y, m, _ = p["payment_date"].split("-")
        p["payment_date"] = f"{y}-{m}-32"
    elif kind == "unknown_loan":
        p["loan_id"] = f"LN9{rng.randint(0, 999999):06d}"
    else:
        extra.append(dict(p))
payments.extend(extra)
payments.sort(key=lambda p: (p["payment_date"], p["payment_id"]))

# ------------------------------------------------------------ January changes
moved = rng.sample([c for c in customers if c["created_at"].date() <= SEED_CUTOFF], 300)
seed_state = {c["customer_id"]: (c["occupation"], c["monthly_income"], c["city"], c["province"]) for c in customers}
for c in moved:
    if rng.random() < 0.6:
        new_branch = rng.choice([b for b in BRANCHES if b[1] != c["city"]])
        c["city"], c["province"] = new_branch[1], new_branch[2]
    else:
        c["monthly_income"] = round_to(c["monthly_income"] * rng.uniform(1.05, 1.30), 100_000)
    c["updated_at"] = random_time(random_date(date(2026, 1, 2), date(2026, 1, 28)))


# ------------------------------------------------------------------- output
def customer_row(c, state=None):
    occupation, income, city, province = state or (c["occupation"], c["monthly_income"], c["city"], c["province"])
    updated = c["created_at"] if state else c["updated_at"]
    return (c["customer_id"], c["full_name"], c["gender"], c["birth_date"], occupation, income,
            city, province, c["created_at"], updated)


def loan_row(l):
    return (l["loan_id"], l["customer"]["customer_id"], l["branch_id"], l["product_id"], l["application_date"],
            l["disbursement_date"], l["principal_amount"], l["interest_rate_flat"], l["tenor_months"],
            l["installment_amount"], l["created_at"], l["updated_at"])


CUSTOMER_COLS = ["customer_id", "full_name", "gender", "birth_date", "occupation", "monthly_income",
                 "city", "province", "created_at", "updated_at"]
LOAN_COLS = ["loan_id", "customer_id", "branch_id", "product_id", "application_date", "disbursement_date",
             "principal_amount", "interest_rate_flat", "tenor_months", "installment_amount", "created_at", "updated_at"]
opened = datetime(2022, 1, 3, 8, 0, 0)

(ROOT / "source").mkdir(exist_ok=True)
seed_customers = [c for c in customers if c["created_at"].date() <= SEED_CUTOFF]
seed_loans = [l for l in loans if l["disbursement_date"] <= SEED_CUTOFF]
with open(ROOT / "source" / "loancore_seed.sql", "w", encoding="utf-8", newline="\n") as f:
    f.write("-- Generated by scripts/generate_data.py. LoanCore state as of 2025-12-31.\nUSE LoanCore;\nSET NOCOUNT ON;\n\n")
    f.write(insert_statements("dbo.branch", ["branch_id", "branch_name", "city", "province", "region", "opened_date", "updated_at"],
                              [(b[0], f"Cabang {b[1]}", b[1], b[2], b[3], opened.date(), opened) for b in BRANCHES]))
    f.write(insert_statements("dbo.product", ["product_id", "product_name", "category", "interest_rate_flat", "updated_at"],
                              [(p[0], p[1], p[2], p[3], opened) for p in PRODUCTS]))
    f.write(insert_statements("dbo.customer", CUSTOMER_COLS, [customer_row(c, seed_state[c["customer_id"]]) for c in seed_customers]))
    f.write(insert_statements("dbo.loan", LOAN_COLS, [loan_row(l) for l in seed_loans]))

new_customers = [c for c in customers if c["created_at"].date() > SEED_CUTOFF]
new_loans = [l for l in loans if l["disbursement_date"] > SEED_CUTOFF]
with open(ROOT / "source" / "loancore_changes.sql", "w", encoding="utf-8", newline="\n") as f:
    f.write("-- Generated by scripts/generate_data.py. Changes made in LoanCore during January 2026.\nUSE LoanCore;\nSET NOCOUNT ON;\n\n")
    for c in moved:
        f.write(f"UPDATE dbo.customer SET monthly_income = {c['monthly_income']}, city = {sql_value(c['city'])}, "
                f"province = {sql_value(c['province'])}, updated_at = {sql_value(c['updated_at'])} "
                f"WHERE customer_id = '{c['customer_id']}';\n")
    f.write("\n")
    f.write(insert_statements("dbo.customer", CUSTOMER_COLS, [customer_row(c) for c in new_customers]))
    f.write(insert_statements("dbo.loan", LOAN_COLS, [loan_row(l) for l in new_loans]))

for folder in ("incoming", "next_month", "archive"):
    (ROOT / "data" / folder).mkdir(parents=True, exist_ok=True)
by_month: dict[str, list[dict]] = {}
for p in payments:
    by_month.setdefault(p["payment_date"][:7].replace("-", ""), []).append(p)
for month, rows in sorted(by_month.items()):
    folder = "next_month" if month > SEED_CUTOFF.strftime("%Y%m") else "incoming"
    with open(ROOT / "data" / folder / f"payments_{month}.csv", "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["payment_id", "loan_id", "installment_no", "payment_date", "amount", "channel"])
        writer.writeheader()
        writer.writerows(rows)

print(f"Customers: {len(seed_customers)} initial + {len(new_customers)} new in January, {len(moved)} changed")
print(f"Loans: {len(seed_loans)} initial + {len(new_loans)} new in January")
print(f"Payments: {len(payments)} rows in {len(by_month)} monthly files")
print(f"Dirty rows injected: {dirty}")
