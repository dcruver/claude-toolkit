"""A single small module, so the fixture is a real source tree rather than a stub."""


class Greeter:
    """Greets by name."""

    def __init__(self, greeting: str = "Hello") -> None:
        self.greeting = greeting

    def greet(self, name: str) -> str:
        return f"{self.greeting}, {name}!"
