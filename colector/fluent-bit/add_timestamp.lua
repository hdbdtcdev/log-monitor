function add_timestamp(tag, timestamp, record)
    new_record = record
    new_record["ingested_at"] = os.date("!%Y-%m-%dT%H:%M:%SZ")
    return 1, timestamp, new_record
end
