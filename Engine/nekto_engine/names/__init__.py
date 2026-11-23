"""Имена людей: словарь, разбор упоминаний, поиск в тексте, склейка упоминаний в одного человека."""
from .mention import Mention, Person, latin_key, nominative, parse

__all__ = ["Mention", "Person", "latin_key", "nominative", "parse"]
