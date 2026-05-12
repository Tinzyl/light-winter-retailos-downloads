from app.services.token_service import SAFE_ALPHABET, generate_random_token, normalize_token


def test_token_is_short_human_readable_and_random_shape():
    tokens = {generate_random_token() for _ in range(200)}

    assert len(tokens) == 200
    for token in tokens:
        assert len(token) == 14
        assert token.count("-") == 2
        assert all(char in SAFE_ALPHABET or char == "-" for char in token)


def test_normalize_token_for_manual_whatsapp_entry():
    assert normalize_token(" abcd efgh ") == "ABCD-EFGH"
