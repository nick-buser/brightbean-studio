"""Security regression tests for approvals comments (V9)."""

from django.test import TestCase
from django.urls import reverse
from django.utils import timezone

from apps.accounts.models import User
from apps.approvals.models import PostComment
from apps.composer.models import Post
from apps.members.models import OrgMembership, WorkspaceMembership
from apps.organizations.models import Organization
from apps.workspaces.models import Workspace


def _make_user(email):
    user = User.objects.create_user(
        email=email,
        password="testpass123",
        tos_accepted_at=timezone.now(),
    )
    # The accounts post_save signal auto-provisions a default Organization +
    # Workspace + OrgMembership for every new User. Tests that want to attach
    # the user to a specific org must start from a clean slate, otherwise the
    # RBAC middleware (which does OrgMembership.objects.filter(...).first())
    # may pick the auto-org instead of the test org.
    from apps.members.models import OrgMembership, WorkspaceMembership
    from apps.organizations.models import Organization

    auto_org_ids = list(OrgMembership.objects.filter(user=user).values_list("organization_id", flat=True))
    WorkspaceMembership.objects.filter(user=user).delete()
    OrgMembership.objects.filter(user=user).delete()
    Organization.objects.filter(id__in=auto_org_ids).delete()
    return user


class EditCommentWorkspaceScopeTests(TestCase):
    """V9: edit_comment must reject cross-workspace post_id."""

    def setUp(self):
        self.org = Organization.objects.create(name="Test Org")
        self.ws_a = Workspace.objects.create(organization=self.org, name="WS-A")
        self.ws_b = Workspace.objects.create(organization=self.org, name="WS-B")
        self.user = _make_user("user@example.com")
        OrgMembership.objects.create(user=self.user, organization=self.org, org_role="owner")
        WorkspaceMembership.objects.create(user=self.user, workspace=self.ws_a, workspace_role="editor")
        WorkspaceMembership.objects.create(user=self.user, workspace=self.ws_b, workspace_role="editor")

        self.post_b = Post.objects.create(workspace=self.ws_b, author=self.user, caption="b")
        self.comment = PostComment.objects.create(
            post=self.post_b,
            author=self.user,
            body="hi",
            visibility=PostComment.Visibility.INTERNAL,
        )

    def test_cross_workspace_edit_returns_404(self):
        self.client.force_login(self.user)
        # Edit a comment that lives in WS-B, but POST through WS-A's URL.
        url = reverse(
            "approvals:edit_comment",
            kwargs={
                "workspace_id": self.ws_a.id,
                "post_id": self.post_b.id,
                "comment_id": self.comment.id,
            },
        )
        response = self.client.post(url, data={"body": "rewritten"})
        self.assertEqual(response.status_code, 404)
        self.comment.refresh_from_db()
        self.assertEqual(self.comment.body, "hi")

    def test_same_workspace_edit_succeeds(self):
        self.client.force_login(self.user)
        url = reverse(
            "approvals:edit_comment",
            kwargs={
                "workspace_id": self.ws_b.id,
                "post_id": self.post_b.id,
                "comment_id": self.comment.id,
            },
        )
        response = self.client.post(url, data={"body": "rewritten"})
        self.assertLess(response.status_code, 400)
        self.comment.refresh_from_db()
        self.assertEqual(self.comment.body, "rewritten")


class DeleteCommentWorkspaceScopeTests(TestCase):
    """delete_comment must not act on a comment outside the request workspace.

    The permission check resolves the caller's membership in the workspace taken
    from the URL, so an unscoped comment lookup would authorise a manager in one
    workspace against a comment in another.
    """

    def setUp(self):
        self.org = Organization.objects.create(name="Test Org")
        self.ws_a = Workspace.objects.create(organization=self.org, name="WS-A")
        self.ws_b = Workspace.objects.create(organization=self.org, name="WS-B")

        # Manager in WS-A only — never a member of WS-B.
        self.manager_a = _make_user("manager-a@example.com")
        OrgMembership.objects.create(user=self.manager_a, organization=self.org, org_role="member")
        WorkspaceMembership.objects.create(user=self.manager_a, workspace=self.ws_a, workspace_role="manager")

        # The comment lives in WS-B and belongs to someone else entirely.
        self.manager_b = _make_user("manager-b@example.com")
        OrgMembership.objects.create(user=self.manager_b, organization=self.org, org_role="member")
        WorkspaceMembership.objects.create(user=self.manager_b, workspace=self.ws_b, workspace_role="manager")

        self.post_a = Post.objects.create(workspace=self.ws_a, author=self.manager_a, caption="a")
        self.post_b = Post.objects.create(workspace=self.ws_b, author=self.manager_b, caption="b")
        self.comment_b = PostComment.objects.create(
            post=self.post_b,
            author=self.manager_b,
            body="b-comment",
            visibility=PostComment.Visibility.INTERNAL,
        )

    def _delete_url(self, workspace, post, comment):
        return reverse(
            "approvals:delete_comment",
            kwargs={
                "workspace_id": workspace.id,
                "post_id": post.id,
                "comment_id": comment.id,
            },
        )

    def test_cross_workspace_delete_returns_404(self):
        """Foreign post_id — the view must resolve it before mutating."""
        self.client.force_login(self.manager_a)
        url = self._delete_url(self.ws_a, self.post_b, self.comment_b)
        response = self.client.post(url)
        self.assertEqual(response.status_code, 404)
        self.comment_b.refresh_from_db()
        self.assertIsNone(self.comment_b.deleted_at)

    def test_own_workspace_post_id_cannot_delete_foreign_comment(self):
        """A post_id the caller legitimately owns must not carry a foreign
        comment_id through — the service lookup is the boundary here."""
        self.client.force_login(self.manager_a)
        url = self._delete_url(self.ws_a, self.post_a, self.comment_b)
        response = self.client.post(url)
        self.assertGreaterEqual(response.status_code, 400)
        self.comment_b.refresh_from_db()
        self.assertIsNone(self.comment_b.deleted_at)

    def test_same_workspace_delete_succeeds(self):
        self.client.force_login(self.manager_b)
        url = self._delete_url(self.ws_b, self.post_b, self.comment_b)
        response = self.client.post(url)
        self.assertLess(response.status_code, 400)
        self.comment_b.refresh_from_db()
        self.assertIsNotNone(self.comment_b.deleted_at)
