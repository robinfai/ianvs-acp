import { cleanup, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import axe from "axe-core";
import { afterEach, describe, expect, it } from "vitest";
import { App } from "./App.jsx";

afterEach(cleanup);

function queueSummary() {
  return screen.getByLabelText("Queue summary");
}

describe("Inbox autopilot acceptance", () => {
  it("starts with an automatic queue paused at a decision checkpoint", () => {
    render(<App />);

    expect(queueSummary()).toHaveTextContent("1 waiting");
    expect(queueSummary()).toHaveTextContent("2 running");
    expect(queueSummary()).toHaveTextContent("4 queued");
    expect(screen.getByRole("heading", { name: "4. Human checkpoint" })).toBeVisible();
    expect(screen.getByRole("radio", { name: /Use Keychain on macOS/ })).toBeChecked();
    expect(screen.getByText("Auto-resumes after answer")).toBeVisible();
  });

  it("saves a custom answer without resuming the task", async () => {
    const user = userEvent.setup();
    render(<App />);

    await user.type(
      screen.getByPlaceholderText("Explain the behavior you want…"),
      "Use Keychain, but let administrators opt out.",
    );
    await user.click(screen.getByRole("button", { name: "Save answer, keep paused" }));

    expect(screen.getByRole("status")).toHaveTextContent("Answer saved. The task remains paused.");
    expect(queueSummary()).toHaveTextContent("1 waiting");
    expect(queueSummary()).toHaveTextContent("2 running");
    expect(screen.getByText("Paused for input", { selector: ".paused-badge" })).toBeVisible();
  });

  it("resumes from the selected answer and synchronizes the queue state", async () => {
    const user = userEvent.setup();
    render(<App />);

    await user.click(screen.getByRole("radio", { name: /Use encrypted file storage everywhere/ }));
    await user.click(screen.getByRole("button", { name: "Answer & resume" }));

    expect(screen.getByRole("button", { name: "Resuming automatically…" })).toBeDisabled();
    expect(screen.getByText("Applying your answer…")).toBeVisible();

    await waitFor(() => expect(queueSummary()).toHaveTextContent("0 waiting"), { timeout: 1800 });
    expect(queueSummary()).toHaveTextContent("3 running");
    expect(screen.getByText("Answered: Use encrypted file storage everywhere")).toBeVisible();
    expect(screen.getByText("Applying decision: Use encrypted file storage everywhere")).toBeVisible();
    expect(screen.getAllByText("Resumed automatically").length).toBeGreaterThanOrEqual(1);
    expect(screen.getByRole("button", { name: /Update authentication flow.*Running/ })).toHaveClass("task-row--running", "is-selected");

    await user.click(screen.getByRole("button", { name: /Refactor session manager/ }));
    await user.click(screen.getByRole("button", { name: /Update authentication flow.*Running/ }));
    expect(screen.getByText("Answered: Use encrypted file storage everywhere")).toBeVisible();
  });

  it("creates a task with its instructions and starts it immediately", async () => {
    const user = userEvent.setup();
    render(<App />);

    const toolbar = screen.getByRole("banner", { name: "Application toolbar" });
    await user.click(within(toolbar).getByRole("button", { name: "New task" }));
    const dialog = screen.getByRole("dialog", { name: "New automatic task" });
    const createButton = within(dialog).getByRole("button", { name: "Create & run" });
    expect(createButton).toBeDisabled();

    await user.type(within(dialog).getByLabelText("Task title"), "Verify automatic execution");
    await user.type(
      within(dialog).getByLabelText("Instructions"),
      "Confirm the queue updates without manual intervention.",
    );
    await user.click(createButton);

    expect(screen.getByRole("heading", { name: "Verify automatic execution" })).toBeVisible();
    expect(screen.getByText("Confirm the queue updates without manual intervention.")).toBeVisible();
    expect(queueSummary()).toHaveTextContent("3 running");
  });

  it("supports evidence disclosure and linked background context", async () => {
    const user = userEvent.setup();
    render(<App />);

    await user.click(screen.getByRole("button", { name: "+ 6 more" }));
    expect(screen.getByText("docs/security.md")).toBeVisible();
    await user.click(screen.getByRole("button", { name: "View linked session" }));
    expect(screen.getByText("Session auth-storage-review · 42 tests passed")).toBeVisible();

    await user.click(screen.getByRole("button", { name: "Background & evidence" }));
    expect(screen.queryByText("auth/storage.ts")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Background & evidence" })).toHaveAttribute("aria-expanded", "false");
  });

  it("navigates between workspaces and the automatic run queue", async () => {
    const user = userEvent.setup();
    render(<App />);

    await user.click(screen.getByRole("tab", { name: "Workspaces" }));
    expect(screen.getByRole("button", { name: "Open Inbox" })).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Run queue" }));

    expect(screen.getByRole("tab", { name: "Inbox" })).toHaveAttribute("aria-selected", "true");
    expect(screen.getByRole("heading", { name: "Refactor session manager" })).toBeVisible();
  });

  it("closes the new-task dialog with Escape", async () => {
    const user = userEvent.setup();
    render(<App />);

    await user.click(within(screen.getByRole("banner", { name: "Application toolbar" })).getByRole("button", { name: "New task" }));
    const titleInput = screen.getByLabelText("Task title");
    await user.type(titleInput, "Draft task");
    await user.keyboard("{Escape}");

    expect(screen.queryByRole("dialog", { name: "New automatic task" })).not.toBeInTheDocument();
  });

  it("keeps keyboard focus inside the new-task dialog", async () => {
    const user = userEvent.setup();
    render(<App />);

    await user.click(within(screen.getByRole("banner", { name: "Application toolbar" })).getByRole("button", { name: "New task" }));
    await user.type(screen.getByLabelText("Task title"), "Keyboard task");
    const closeButton = screen.getByRole("button", { name: "Close dialog" });
    const createButton = screen.getByRole("button", { name: "Create & run" });
    createButton.focus();
    await user.tab();

    expect(closeButton).toHaveFocus();
  });

  it("has no detectable semantic accessibility violations in core states", async () => {
    const user = userEvent.setup();
    render(<App />);
    const options = { rules: { "color-contrast": { enabled: false } } };

    const inboxResult = await axe.run(document.body, options);
    expect(inboxResult.violations).toEqual([]);

    await user.click(within(screen.getByRole("banner", { name: "Application toolbar" })).getByRole("button", { name: "New task" }));
    const dialogResult = await axe.run(document.body, options);
    expect(dialogResult.violations).toEqual([]);
  });
});
