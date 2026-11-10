import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SQL = (ROOT / "sql" / "gwm_database.sql").read_text(encoding="utf-8")
OUT = ROOT / "docs"

TABLE_DESC = {
    "state": "Australian state or territory.",
    "council": "Local government area that administers waste facilities and levies.",
    "address": "Any physical address, linked to the council that covers it.",
    "waste_category": "Core waste categories: mixed rubbish, building materials, concrete and dirt.",
    "council_facility": "Council dump or recycling facility.",
    "facility_accepted_category": "Link table: waste categories each facility accepts (M:N).",
    "tin_size": "Skip bin sizes with volume and maximum load.",
    "category_tin_size": "Link table: tin sizes permitted for each waste category (M:N).",
    "tin_price": "Hire price for a permitted category and size, by state and effective date.",
    "depot": "Company depot where vehicles, tins and employees are based.",
    "outsource_supplier": "External company providing vehicles and staff.",
    "vehicle": "Company-owned or outsourced vehicle.",
    "vehicle_maintenance": "Service, repair and inspection history for a vehicle.",
    "smart_tin": "Physical IoT-enabled skip bin.",
    "tin_telemetry": "Sensor readings reported by a smart tin.",
    "job_position": "HR position with a base hourly rate.",
    "staff": "Company employees and outsourced contractors.",
    "roster_shift": "Rostered shift for a staff member, optionally with a vehicle.",
    "leave_request": "Leave requested by a staff member and its approval.",
    "timesheet": "Hours actually worked, optionally tied to a rostered shift.",
    "pay_period": "Fortnightly payroll cycle.",
    "payslip": "Pay calculation for one employee in one pay period.",
    "customer": "Residential, commercial or government customer, holding the billing address.",
    "customer_order": "Order header with a separate delivery address and billing snapshot.",
    "order_line": "One smart tin of one waste category and size on an order.",
    "job": "Delivery, pickup or swap carried out with one vehicle.",
    "job_staff": "Link table: crew members assigned to a job (M:N).",
    "disposal_record": "Dump or recycling docket recording weights and fees.",
    "invoice": "Customer invoice for an order.",
    "payment": "Payment received against a customer invoice.",
    "supplier_invoice": "Invoice received from an outsource supplier (accounts payable).",
    "cloud_performance_metric": "Cloud platform performance reading for the BI dashboard.",
    "audit_log": "Record of changes to sensitive data.",
}

COL_DESC = {
    "state_code": "State or territory code, for example NSW.",
    "state_name": "Full state name.",
    "council_name": "Official council name.",
    "contact_email": "Contact email address.",
    "contact_phone": "Contact phone number.",
    "waste_levy_per_tonne": "State waste levy charged per tonne (AUD).",
    "street_line1": "First line of the street address.",
    "street_line2": "Second line of the street address.",
    "suburb": "Suburb or locality.",
    "postcode": "Four digit Australian postcode.",
    "latitude": "Latitude in decimal degrees.",
    "longitude": "Longitude in decimal degrees.",
    "category_code": "Short code: MIXED, BUILDING, CONCRETE or DIRT.",
    "category_name": "Display name of the category.",
    "weight_class": "LIGHT or HEAVY.",
    "description": "Free text description.",
    "facility_name": "Facility name.",
    "facility_type": "DUMP or RECYCLING.",
    "gate_fee_per_tonne": "Gate fee charged per tonne (AUD).",
    "operating_hours": "Opening hours as text.",
    "is_active": "1 if the facility is operating, otherwise 0.",
    "size_code": "Short size code, for example S4.",
    "volume_m3": "Capacity in cubic metres.",
    "max_load_kg": "Maximum permitted load in kilograms.",
    "hire_price": "Hire price in AUD excluding GST.",
    "effective_from": "Date the price takes effect; it applies until a later row for the same combination.",
    "depot_name": "Depot name.",
    "phone": "Phone number.",
    "supplier_name": "Registered supplier name.",
    "abn": "Eleven digit Australian Business Number.",
    "contact_name": "Primary contact person.",
    "daily_vehicle_rate": "Daily rate charged per vehicle (AUD).",
    "hourly_staff_rate": "Hourly rate charged per staff member (AUD).",
    "contract_start": "Contract start date.",
    "contract_end": "Contract end date, null while ongoing.",
    "supplier_status": "ACTIVE, SUSPENDED or ENDED.",
    "registration_no": "Vehicle registration plate.",
    "vehicle_type": "SKIP_TRUCK, HOOK_LIFT, TIPPER or VAN.",
    "make": "Manufacturer.",
    "model": "Model name.",
    "year_built": "Year of manufacture.",
    "capacity_tonnes": "Load capacity in tonnes.",
    "ownership": "OWNED (has a depot) or OUTSOURCED (has a supplier).",
    "vehicle_status": "AVAILABLE, IN_USE, MAINTENANCE or RETIRED.",
    "next_service_due": "Date the next service is due.",
    "service_date": "Date the work was done.",
    "maintenance_type": "SERVICE, REPAIR, INSPECTION or TYRES.",
    "odometer_km": "Odometer reading in kilometres.",
    "cost": "Cost in AUD.",
    "notes": "Free text notes.",
    "tin_serial": "Printed serial number on the tin.",
    "device_imei": "Fifteen digit IMEI of the IoT device.",
    "firmware_version": "Installed device firmware version.",
    "tin_status": "AVAILABLE, DEPLOYED, MAINTENANCE or RETIRED.",
    "purchase_date": "Date the tin was purchased.",
    "last_seen_at": "Time of the latest sensor reading.",
    "recorded_at": "Time the reading was recorded.",
    "fill_level_pct": "How full the tin is, 0 to 100 percent.",
    "weight_kg": "Measured weight in kilograms.",
    "battery_pct": "Device battery level, 0 to 100 percent.",
    "tamper_flag": "1 if tampering was detected.",
    "position_title": "Position title.",
    "base_hourly_rate": "Base hourly pay rate (AUD).",
    "requires_licence": "1 if the position needs a driver licence.",
    "employment_type": "EMPLOYEE (has a depot) or CONTRACTOR (has a supplier).",
    "first_name": "Given name.",
    "last_name": "Family name.",
    "date_of_birth": "Date of birth.",
    "email": "Unique email address.",
    "licence_no": "Driver licence number.",
    "licence_class": "Driver licence class.",
    "licence_expiry": "Driver licence expiry date.",
    "hire_date": "Start date.",
    "termination_date": "End date, null while employed.",
    "hourly_rate": "Hourly pay rate (AUD).",
    "staff_status": "ACTIVE, ON_LEAVE or TERMINATED.",
    "shift_start": "Scheduled start.",
    "shift_end": "Scheduled end.",
    "shift_status": "SCHEDULED, WORKED, ABSENT or CANCELLED.",
    "leave_type": "ANNUAL, SICK, UNPAID or CARER.",
    "start_date": "First day of leave.",
    "end_date": "Last day of leave.",
    "leave_status": "PENDING, APPROVED or REJECTED.",
    "work_date": "Calendar date worked.",
    "clock_in": "Clock in time.",
    "clock_out": "Clock out time.",
    "break_minutes": "Unpaid break in minutes.",
    "regular_hours": "Ordinary hours paid at the base rate.",
    "overtime_hours": "Overtime hours paid at 1.5 times the rate.",
    "timesheet_status": "SUBMITTED, APPROVED or REJECTED.",
    "period_start": "First day of the period.",
    "period_end": "Last day of the period.",
    "pay_date": "Date employees are paid.",
    "period_status": "OPEN, CLOSED or PAID.",
    "gross_pay": "Gross pay before tax (AUD).",
    "tax_withheld": "Income tax withheld (AUD).",
    "super_amount": "Employer superannuation contribution (AUD).",
    "net_pay": "Take home pay (AUD), gross minus tax.",
    "customer_type": "RESIDENTIAL, COMMERCIAL or GOVERNMENT.",
    "company_name": "Company name for commercial and government customers.",
    "credit_limit": "Maximum unpaid balance allowed (AUD).",
    "customer_status": "ACTIVE, SUSPENDED or CLOSED.",
    "created_at": "Time the record was created.",
    "order_number": "Business order number shown to the customer.",
    "ordered_at": "Time the order was placed.",
    "requested_delivery": "Requested delivery date.",
    "requested_pickup": "Requested pickup date.",
    "site_contact_name": "Person to contact at the delivery site.",
    "site_contact_phone": "Phone of the site contact.",
    "order_status": "PLACED, SCHEDULED, DELIVERED, COMPLETED or CANCELLED.",
    "unit_price": "Price charged for the tin (AUD, excluding GST).",
    "job_type": "DELIVERY, PICKUP or SWAP.",
    "scheduled_start": "Planned start time.",
    "actual_start": "Actual start time.",
    "actual_end": "Actual finish time.",
    "job_status": "SCHEDULED, IN_PROGRESS, COMPLETED or CANCELLED.",
    "outsource_cost": "Cost allocated to this job for an outsourced vehicle (AUD).",
    "job_role": "DRIVER or OFFSIDER.",
    "docket_number": "Facility docket number.",
    "disposed_at": "Time the waste was received.",
    "gross_weight_kg": "Weight received in kilograms.",
    "recycled_weight_kg": "Weight diverted to recycling in kilograms.",
    "gate_fee": "Gate fee charged by the facility (AUD).",
    "invoice_number": "Business invoice number.",
    "issue_date": "Date issued.",
    "due_date": "Payment due date.",
    "subtotal": "Amount excluding GST (AUD).",
    "gst_amount": "GST at ten percent (AUD).",
    "total_amount": "Subtotal plus GST (AUD).",
    "invoice_status": "Current status of the invoice.",
    "paid_at": "Time the payment was received.",
    "amount": "Amount paid (AUD).",
    "payment_method": "CARD, BANK_TRANSFER, CASH or BPAY.",
    "reference_no": "Payment reference.",
    "supplier_ref": "Supplier's own invoice reference.",
    "paid_date": "Date the supplier was paid.",
    "service_name": "Platform service being measured.",
    "cloud_region": "Cloud region, for example ap-southeast-2.",
    "metric_name": "Name of the metric.",
    "metric_value": "Measured value.",
    "metric_unit": "Unit of the value.",
    "table_name": "Table that was changed.",
    "record_id": "Primary key value of the changed row.",
    "action_type": "INSERT, UPDATE or DELETE.",
    "changed_by": "Database user that made the change.",
    "changed_at": "Time of the change.",
    "change_detail": "Short description of the change.",
}

FK_ROLE = {
    "billing_address_id": "Billing address.",
    "delivery_address_id": "Delivery address for this order, separate from billing.",
    "approver_id": "Staff member who approved it.",
    "tin_id": "Smart tin assigned.",
    "address_id": "Address of this record.",
}


def split_top(s):
    parts, depth, cur = [], 0, ""
    for ch in s:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        parts.append(cur.strip())
    return parts


def cols(s):
    return [c.strip().lower() for c in s.split(",")]


tables = {}
order = []
section1 = SQL.split("SECTION 2 - INDEXES")[0]
for m in re.finditer(r"CREATE TABLE (\w+) \((.*?)\n\);", section1, re.S):
    name = m.group(1).lower()
    body = "\n".join(re.sub(r"--.*$", "", l) for l in m.group(2).splitlines())
    t = {"cols": [], "pk": [], "uniques": [], "fks": [], "checks": []}
    for part in split_top(body):
        part = " ".join(part.split())
        cm = re.match(r"CONSTRAINT \w+ (PRIMARY KEY|UNIQUE|FOREIGN KEY|CHECK) (.*)", part, re.I)
        if cm:
            kind, rest = cm.group(1).upper(), cm.group(2)
            if kind == "PRIMARY KEY":
                t["pk"] = cols(re.match(r"\((.*?)\)", rest).group(1))
            elif kind == "UNIQUE":
                t["uniques"].append(cols(re.match(r"\((.*?)\)", rest).group(1)))
            elif kind == "FOREIGN KEY":
                fm = re.match(r"\((.*?)\) REFERENCES (\w+) \((.*?)\)", rest)
                t["fks"].append((cols(fm.group(1)), fm.group(2).lower(), cols(fm.group(3))))
            else:
                t["checks"].append(rest)
            continue
        colm = re.match(r"(\w+) (NUMBER|VARCHAR2|DATE|TIMESTAMP)(?:\(([^)]*)\))?(.*)", part)
        rest = colm.group(4)
        t["cols"].append({
            "name": colm.group(1).lower(),
            "type": colm.group(2),
            "size": colm.group(3),
            "null": "NOT NULL" not in rest.upper(),
            "identity": "IDENTITY" in rest.upper(),
        })
    # identity columns form the primary key when declared inline
    tables[name] = t
    order.append(name)

for name, t in tables.items():
    for c in t["cols"]:
        c["pk"] = c["name"] in t["pk"]
        if c["pk"]:
            c["null"] = False
        c["fk"] = any(c["name"] in fk[0] for fk in t["fks"])
        c["uk"] = any(u == [c["name"]] for u in t["uniques"])


def type_text(c):
    return c["type"] + (f"({c['size']})" if c["size"] else "")


def describe(tname, c):
    n = c["name"]
    if c["pk"] and c["identity"]:
        return "Surrogate primary key, generated by Oracle."
    for fk in tables[tname]["fks"]:
        if n in fk[0]:
            idx = fk[0].index(n)
            base = FK_ROLE.get(n, "")
            ref = f"References {fk[1]}.{fk[2][idx]}."
            if c["pk"]:
                return f"Part of the primary key. {ref}"
            return f"{base} {ref}".strip()
    if n in COL_DESC:
        return COL_DESC[n]
    return n.replace("_", " ").capitalize() + "."


def relationships():
    rels = []
    for child in order:
        t = tables[child]
        for fcols, parent, pcols in t["fks"]:
            nullable = any(c["null"] for c in t["cols"] if c["name"] in fcols)
            one_to_one = sorted(fcols) in [sorted(u) for u in t["uniques"]] or sorted(fcols) == sorted(t["pk"])
            rels.append({
                "parent": parent, "child": child, "cols": fcols,
                "optional": nullable, "one_to_one": one_to_one,
            })
    return rels


RELS = relationships()


def mermaid(include, title=None):
    lines = []
    if title:
        lines.append("---")
        lines.append(f"title: {title}")
        lines.append("---")
    lines.append("erDiagram")
    for r in RELS:
        if r["parent"] in include and r["child"] in include:
            left = "|o" if r["optional"] else "||"
            right = "o|" if r["one_to_one"] else "o{"
            label = ", ".join(r["cols"])
            lines.append(f'    {r["parent"].upper()} {left}--{right} {r["child"].upper()} : "{label}"')
    for name in order:
        if name not in include:
            continue
        lines.append(f"    {name.upper()} {{")
        for c in tables[name]["cols"]:
            keys = [k for k, f in (("PK", c["pk"]), ("FK", c["fk"]), ("UK", c["uk"])) if f]
            size = f"({c['size']})" if c["size"] else ""
            note = f"{size} {'null' if c['null'] else 'not null'}".strip()
            key_txt = (" " + ",".join(keys)) if keys else ""
            lines.append(f'        {c["type"].lower()} {c["name"]}{key_txt} "{note}"')
        lines.append("    }")
    return "\n".join(lines) + "\n"


DOMAINS = {
    "erd_full": ("GWM complete ERD", order),
    "erd_locality": ("Locality, councils and facilities",
                     ["state", "council", "address", "council_facility", "facility_accepted_category",
                      "waste_category", "disposal_record", "order_line", "job"]),
    "erd_ordering": ("Customers, ordering and billing",
                     ["customer", "address", "customer_order", "order_line", "waste_category", "tin_size",
                      "category_tin_size", "tin_price", "state", "smart_tin", "job", "invoice", "payment"]),
    "erd_fleet": ("Fleet, smart tins and field operations",
                  ["vehicle", "vehicle_maintenance", "outsource_supplier", "supplier_invoice", "depot",
                   "smart_tin", "tin_telemetry", "tin_size", "job", "job_staff", "staff", "order_line",
                   "disposal_record", "council_facility", "address"]),
    "erd_people": ("Personnel, rostering, timesheets and payroll",
                   ["staff", "job_position", "depot", "outsource_supplier", "roster_shift", "vehicle",
                    "leave_request", "timesheet", "pay_period", "payslip", "job_staff", "job", "address"]),
}

for fname, (title, tl) in DOMAINS.items():
    (OUT / f"{fname}.mmd").write_text(mermaid(set(tl), title), encoding="utf-8")


def dictionary_md():
    out = []
    for n, name in enumerate(order, 1):
        t = tables[name]
        out.append(f"### Entity {n}: {name.upper()}\n")
        out.append(f"{TABLE_DESC[name]}\n")
        out.append("| Attribute | Data type | Key | Null | Description |")
        out.append("|" + "-" * 22 + "|" + "-" * 15 + "|" + "-" * 8 + "|" + "-" * 6 + "|" + "-" * 49 + "|")
        for c in t["cols"]:
            keys = ", ".join(k for k, f in (("PK", c["pk"]), ("FK", c["fk"]), ("UK", c["uk"])) if f)
            out.append(f"| {c['name']} | {type_text(c)} | {keys} | {'Yes' if c['null'] else 'No'} | {describe(name, c)} |")
        out.append("")
    return "\n".join(out)


def is_link(name):
    t = tables[name]
    return len(t["pk"]) == 2 and len(t["fks"]) == 2 and all(c["fk"] for c in t["cols"] if c["pk"])


def relationships_md():
    out = ["| # | Parent entity | Cardinality | Child entity | Foreign key | Child participation |",
           "|" + "|".join("-" * w for w in (4, 24, 11, 24, 23, 14)) + "|"]
    for i, r in enumerate(RELS, 1):
        card = "1:1" if r["one_to_one"] else "1:M"
        part = "Optional" if r["optional"] else "Mandatory"
        out.append(f"| {i} | {r['parent'].upper()} | {card} | {r['child'].upper()} | {', '.join(r['cols'])} | {part} |")
    links = [n for n in order if is_link(n)]
    out.append("")
    out.append("Many-to-many relationships are resolved with link tables: " +
               ", ".join(f"{n.upper()} ({' and '.join(tables[n]['pk']).replace('_id', '').upper()})" for n in links) + ".")
    return "\n".join(out)


def replace_block(text, tag, content):
    pat = re.compile(rf"<!-- BEGIN {tag} -->.*?<!-- END {tag} -->", re.S)
    return pat.sub(lambda m: f"<!-- BEGIN {tag} -->\n{content}\n<!-- END {tag} -->", text)


report = (OUT / "report.md").read_text(encoding="utf-8")
report = replace_block(report, "DICTIONARY", dictionary_md())
report = replace_block(report, "RELATIONSHIPS", relationships_md())
(OUT / "report.md").write_text(report, encoding="utf-8")

print("tables:", len(order), "relationships:", len(RELS),
      "one-to-one:", [(r["parent"], r["child"]) for r in RELS if r["one_to_one"]])
