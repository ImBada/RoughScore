#!/usr/bin/env python3
"""Reject empty Swift Testing runs and a silently unexecuted audio fixture test."""

import json
from pathlib import Path
import re
import sys

INTAKE_TESTS = [
    "nativeCallbackQueuesFirstWinsAndStartsLifecycleOnce",
    "structuralRejectionsNeverPromptCancelStartupOrMutate",
    "automaticStartupLateAIsInvalidatedAndCannotReleaseExplicitBOrFallback",
    "cancelledExplicitDoesNotResumeStartupAndLateACannotReportSuccessOverB",
    "dirtyFailureAndCancelRetainDestinationHistoryAndBaseline",
    "modalReentryCannotBorrowDiscardAuthorization",
    "saveSuccessAllowsExactStorageRebaseButRejectsRememberCallbackMutation",
    "savePanelReentryRejectsSecondRequestAndKeepsCancelledWork",
    "busyWorkRejectsWithoutPreemption",
    "dragPreviewIsPreservedUntilAuthorizationAndNeverCommitted",
    "collectedOfflineAndUnicodeUppercaseLinkedUseValidatedReaders",
    "successfulNativeLoadPausesPlayersRestoresBoundedSessionAndRejectsSameUUIDActions",
    "shutdownClearsQueuedAndLateRequestsAndReplacementCannotDrain",
    "exportRenderAndDestinationReentryRejectNativeRequestsWithoutCancellingExport",
    "nativeMemoCaretMarkedTextAndUndoSurviveCancelledOrFailedOpen",
    "saveAndContinueRebasesDemoAudioThroughTheOrdinaryWriterBeforeOpening",
    "coordinatorShutdownOrOwnerReplacementCancelsInFlightWithoutLateCommit",
]

def verify(log, minimum=72):
    text = re.sub(r"\x1b\[[0-9;]*m", "", log)
    summaries = re.findall(r"Test run with (\d+) tests(?: in \d+ suites)? passed", text)
    if not summaries or int(summaries[-1]) < minimum:
        raise ValueError(f"Expected at least {minimum} executed Swift Testing cases")
    if "Real audio:" not in text:
        raise ValueError("Generated fixture integration did not execute its decode assertions")
    if not re.search(r"Test realAudioFixtureWhenProvided\(\) passed", text):
        raise ValueError("Generated fixture integration test did not pass")
    if "Suite ExternalProjectIntakeTests passed" not in text:
        raise ValueError("Native external project intake suite did not execute/pass")
    for name in INTAKE_TESTS:
        if not re.search(r"Test " + name + r"\([^\n]*\)(?: with \d+ test cases)? passed", text):
            raise ValueError("Native external project intake case did not pass: " + name)
    return {
        "swiftTestingCases": int(summaries[-1]),
        "generatedCompressedIntegration": "passed",
        "nativeExternalIntakeFunctions": len(INTAKE_TESTS),
        "realGuitarEvaluation": "skipped: no licensed/labeled real-guitar dataset supplied",
    }


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: verify_test_log.py TEST_LOG")
    try:
        print(json.dumps(verify(Path(sys.argv[1]).read_text()), indent=2))
    except ValueError as error:
        raise SystemExit(str(error))
