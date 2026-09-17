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

// Validates a canonical UUIDv4 (36 chars) and writes a lowercased copy.
// Used before a UUID is turned into a file path, so traversal/odd input is rejected.
bool RV_NormalizeUUID(const char[] input, char[] output, int maxlen)
{
    if (maxlen < 37) return false;

    char buf[64];
    strcopy(buf, sizeof(buf), input);
    TrimString(buf);
    if (strlen(buf) != 36) return false;

    for (int i = 0; i < 36; i++)
    {
        char c = buf[i];
        if (c >= 'A' && c <= 'Z') c += 32;
        if (i == 8 || i == 13 || i == 18 || i == 23)
        {
            if (c != '-') return false;
        }
        else if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
        {
            return false;
        }
        buf[i] = c;
    }

    if (buf[14] != '4') return false;
    char variantChar = buf[19];
    if (variantChar != '8' && variantChar != '9' && variantChar != 'a' && variantChar != 'b') return false;

    strcopy(output, maxlen, buf);
    return true;
}
