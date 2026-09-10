from __future__ import annotations


def format_korean_currency(amount: int) -> str:
    """Formats an integer KRW amount into traditional Korean verbal currency notation.

    Examples:
        50000000 -> "금 오천만원정"
        125000000 -> "금 일억이천오백만원정"
        150000 -> "금 십오만원정"
        30000 -> "금 삼만원정"
        0 -> "금 영원정"
    """
    if amount == 0:
        return "금 영원정"
    if amount < 0:
        return f"-{format_korean_currency(abs(amount))}"

    digits = ("", "일", "이", "삼", "사", "오", "육", "칠", "팔", "구")
    small_units = ("", "십", "백", "천")
    big_units = ("", "만", "억", "조", "경")

    result_parts: list[str] = []
    temp = amount
    unit_idx = 0

    while temp > 0:
        chunk = temp % 10000
        temp //= 10000

        if chunk > 0:
            chunk_str = ""
            for d in range(4):
                digit = (chunk // (10**d)) % 10
                if digit > 0:
                    small_unit = small_units[d]
                    if d > 0 and digit == 1:
                        chunk_str = small_unit + chunk_str
                    else:
                        chunk_str = digits[digit] + small_unit + chunk_str

            big_unit = big_units[unit_idx] if unit_idx < len(big_units) else ""
            result_parts.append(chunk_str + big_unit)

        unit_idx += 1

    verbal = "".join(reversed(result_parts))
    return f"금 {verbal}원정"
