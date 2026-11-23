"""Точка входа движка внутри Nekto.app. Бандл подписан и только для чтения — байткод не пишем."""
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from nekto_engine.server import main  # noqa: E402

main()
