import dataclasses
from asyncio import AbstractEventLoop
from typing import Callable


@dataclasses.dataclass
class Benchmark:
	name: str
	function: Callable[[AbstractEventLoop, int], None]

