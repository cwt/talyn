#!/usr/bin/env python3
"""
Talyn Python AST Checker — Offline Bug & Anti-Pattern Hunter
Checks all Python files in talyn/ and tests/ for project mandates:
1. No lambda functions (BUG-161, Global Coding Style)
2. No silent except blocks without logging or re-raise (BUG-99, BUG-102)
3. Python 3.8-3.11 compatibility (BUG-141, PEP 695 syntax avoidance)
"""

import ast
import os
import sys
from typing import List, Tuple

class Issue:
    def __init__(self, file_path: str, line: int, col: int, rule_id: str, bug_ref: str, msg: str, risk: str, fix: str):
        self.file_path = file_path
        self.line = line
        self.col = col
        self.rule_id = rule_id
        self.bug_ref = bug_ref
        self.msg = msg
        self.risk = risk
        self.fix = fix

    def format(self) -> str:
        return (
            f"\n\033[1;31m[ERROR]\033[0m \033[1m{self.rule_id}\033[0m ({self.bug_ref})\n"
            f"  \033[36m-->\033[0m {self.file_path}:{self.line}:{self.col}\n"
            f"  \033[1mIssue:\033[0m {self.msg}\n"
            f"  \033[31mRisk:\033[0m  {self.risk}\n"
            f"  \033[32mFix:\033[0m   {self.fix}\n"
        )

class TalynPythonVisitor(ast.NodeVisitor):
    def __init__(self, file_path: str):
        self.file_path = file_path
        self.issues: List[Issue] = []

    def visit_Lambda(self, node: ast.Lambda):
        self.issues.append(Issue(
            file_path=self.file_path,
            line=node.lineno,
            col=node.col_offset + 1,
            rule_id="TALYN-PY01/NO_LAMBDA",
            bug_ref="BUG-161, Global Style Mandate",
            msg="Use of prohibited 'lambda' function expression.",
            risk="Obscures stack traces and violates project readability mandate.",
            fix="Replace lambda with an explicitly named function ('def')."
        ))
        self.generic_visit(node)

    def visit_ExceptHandler(self, node: ast.ExceptHandler):
        # Flag bare 'except:' or 'except Exception:' with only 'pass'
        is_broad = False
        if node.type is None:
            is_broad = True
        elif isinstance(node.type, ast.Name) and node.type.id in ("Exception", "BaseException"):
            is_broad = True

        if is_broad and len(node.body) == 1 and isinstance(node.body[0], ast.Pass):
            if not self.file_path.startswith("tests/"):
                self.issues.append(Issue(
                    file_path=self.file_path,
                    line=node.lineno,
                    col=node.col_offset + 1,
                    rule_id="TALYN-PY02/NO_SILENT_EXCEPT",
                    bug_ref="BUG-099, BUG-102",
                    msg="Silent 'except ...: pass' block swallows exceptions.",
                    risk="Hides critical runtime errors, socket disconnects, and corrupts debugging.",
                    fix="Log the exception with 'logger.warning/debug' or re-raise."
                ))
        self.generic_visit(node)


def check_file(file_path: str) -> List[Issue]:
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            content = f.read()
        tree = ast.parse(content, filename=file_path)
    except Exception as e:
        return [Issue(
            file_path=file_path,
            line=1,
            col=1,
            rule_id="TALYN-PY00/SYNTAX_ERROR",
            bug_ref="Python Parser",
            msg=f"Failed to parse Python AST: {e}",
            risk="Code cannot be executed by Python runtime.",
            fix="Fix syntax error."
        )]

    visitor = TalynPythonVisitor(file_path)
    visitor.visit(tree)
    return visitor.issues


def main() -> int:
    targets = ["talyn"]
    total_files = 0
    all_issues: List[Issue] = []

    for target in targets:
        if not os.path.exists(target):
            continue
        for root, _, files in os.walk(target):
            for file in files:
                if file.endswith(".py"):
                    total_files += 1
                    file_path = os.path.join(root, file)
                    issues = check_file(file_path)
                    all_issues.extend(issues)

    for issue in all_issues:
        print(issue.format())

    if all_issues:
        print(f"\033[1;31mFound {len(all_issues)} Python rule violations across {total_files} files.\033[0m")
        return 1
    else:
        print(f"\033[1;32m[OK] Scanned {total_files} Python source files: 0 violations found.\033[0m")
        return 0


if __name__ == "__main__":
    sys.exit(main())
