// uuid.sp - UUIDv4 pure SourcePawn

void RV_GenerateUUID(char[] buf, int maxlen)
{
    if (maxlen < 37) return;
    int r[16];
    for (int i = 0; i < 16; i++)
    {
        r[i] = GetURandomInt() & 0xFF;
        if (r[i] == 0) r[i] = GetRandomInt(0, 255) & 0xFF;
    }
    r[6] = (r[6] & 0x0F) | 0x40; // version 4
    r[8] = (r[8] & 0x3F) | 0x80; // variant 10xx
    FormatEx(buf, maxlen,
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        r[0], r[1], r[2], r[3],
        r[4], r[5],
        r[6], r[7],
        r[8], r[9],
        r[10], r[11], r[12], r[13], r[14], r[15]);
}
