"""
严格测试：管理员向门户用户颁发额度 API

覆盖场景：
1. 正常颁发：POST /api/admin/users/{id}/grant-quota 增加次数
2. 零次数被拒：amount=0 返回 422
3. 负数被拒：amount=-10 返回 422
4. 用户不存在：404
5. 未鉴权：401
6. 累计颁发：多次颁发后总量正确
7. 端到端：颁发额度后 /api/v1/solve 由 403 变为成功（mock token）
"""
import asyncio
import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import httpx
from fastapi import FastAPI

from src.api import admin as admin_api
from src.api import service as service_api
from src.core.auth import (
    issue_admin_token,
    set_database,
)
from src.core.config import config
from src.core.database import Database
from src.services.captcha_runtime import CaptchaRuntime


# ---------------------------------------------------------------------------
# 辅助：构建含 admin router 和 service router 的测试 App
# ---------------------------------------------------------------------------
class _FakeCluster:
    async def dispatch_solve(self, *a, **kw):
        raise AssertionError("should not dispatch in standalone test")


def _make_app(db: Database, runtime: CaptchaRuntime) -> FastAPI:
    cluster = _FakeCluster()
    app = FastAPI()

    admin_api.set_dependencies(db, runtime, cluster)
    service_api.set_dependencies(db, runtime, cluster)
    set_database(db)

    app.include_router(admin_api.router)
    app.include_router(service_api.router)
    return app


class AdminGrantQuotaTests(unittest.IsolatedAsyncioTestCase):
    """核心 API 测试：POST /api/admin/users/{id}/grant-quota"""

    async def asyncSetUp(self):
        self.env_patcher = patch.dict(
            os.environ, {"FCS_CLUSTER_ROLE": "standalone"}, clear=False
        )
        self.env_patcher.start()

        self.temp_dir = tempfile.TemporaryDirectory()
        self.db = Database(Path(self.temp_dir.name) / "grant.sqlite3")
        await self.db.init_db()

        self.runtime = CaptchaRuntime(self.db)
        self.app = _make_app(self.db, self.runtime)

        self.client = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=self.app),
            base_url="http://testserver",
        )

        # 创建测试用户（quota_remaining 默认 0）
        ok, _msg, user_data = await self.db.create_portal_user(
            username="quota_test_user",
            password="test-password",
            register_location="test",
            display_name="测试用户",
        )
        self.assertTrue(ok, _msg)
        self.user_id = user_data["id"]

        # 颁发管理员 token
        self.admin_token = issue_admin_token()

    async def asyncTearDown(self):
        try:
            await self.client.aclose()
            await self.runtime.close()
            await self.db.close()
            for i in range(5):
                try:
                    self.temp_dir.cleanup()
                    break
                except (PermissionError, NotADirectoryError):
                    if i >= 4:
                        raise
                    await asyncio.sleep(0.05)
        finally:
            self.env_patcher.stop()

    # ------------------------------------------------------------------
    # 1. 正常颁发
    # ------------------------------------------------------------------
    async def test_grant_quota_increases_quota_remaining(self):
        resp = await self.client.post(
            f"/api/admin/users/{self.user_id}/grant-quota",
            json={"amount": 50},
            headers={"Authorization": f"Bearer {self.admin_token}"},
        )
        self.assertEqual(resp.status_code, 200, resp.text)
        body = resp.json()
        self.assertTrue(body["success"])
        self.assertEqual(body["granted"], 50)
        self.assertEqual(body["item"]["quota_remaining"], 50)

    # ------------------------------------------------------------------
    # 2. 零次数被拒（Pydantic ge=1 → 422）
    # ------------------------------------------------------------------
    async def test_grant_quota_zero_amount_rejected(self):
        resp = await self.client.post(
            f"/api/admin/users/{self.user_id}/grant-quota",
            json={"amount": 0},
            headers={"Authorization": f"Bearer {self.admin_token}"},
        )
        self.assertEqual(resp.status_code, 422, resp.text)

    # ------------------------------------------------------------------
    # 3. 负数被拒（Pydantic ge=1 → 422）
    # ------------------------------------------------------------------
    async def test_grant_quota_negative_amount_rejected(self):
        resp = await self.client.post(
            f"/api/admin/users/{self.user_id}/grant-quota",
            json={"amount": -100},
            headers={"Authorization": f"Bearer {self.admin_token}"},
        )
        self.assertEqual(resp.status_code, 422, resp.text)

    # ------------------------------------------------------------------
    # 4. 用户不存在
    # ------------------------------------------------------------------
    async def test_grant_quota_nonexistent_user_returns_404(self):
        resp = await self.client.post(
            "/api/admin/users/99999/grant-quota",
            json={"amount": 10},
            headers={"Authorization": f"Bearer {self.admin_token}"},
        )
        self.assertEqual(resp.status_code, 404, resp.text)

    # ------------------------------------------------------------------
    # 5. 未鉴权返回 401
    # ------------------------------------------------------------------
    async def test_grant_quota_without_token_returns_401(self):
        resp = await self.client.post(
            f"/api/admin/users/{self.user_id}/grant-quota",
            json={"amount": 10},
        )
        self.assertEqual(resp.status_code, 401, resp.text)

    # ------------------------------------------------------------------
    # 6. 累计颁发
    # ------------------------------------------------------------------
    async def test_grant_quota_accumulates_across_multiple_calls(self):
        for amt in [30, 20, 50]:
            resp = await self.client.post(
                f"/api/admin/users/{self.user_id}/grant-quota",
                json={"amount": amt},
                headers={"Authorization": f"Bearer {self.admin_token}"},
            )
            self.assertEqual(resp.status_code, 200, resp.text)

        # 验证数据库实际值
        users_resp = await self.client.get(
            "/api/admin/users",
            headers={"Authorization": f"Bearer {self.admin_token}"},
        )
        self.assertEqual(users_resp.status_code, 200)
        items = users_resp.json()["items"]
        user = next((u for u in items if u["id"] == self.user_id), None)
        self.assertIsNotNone(user)
        self.assertEqual(user["quota_remaining"], 100)

    # ------------------------------------------------------------------
    # 7. 缺少 amount 字段 → 422
    # ------------------------------------------------------------------
    async def test_grant_quota_missing_amount_returns_422(self):
        resp = await self.client.post(
            f"/api/admin/users/{self.user_id}/grant-quota",
            json={},
            headers={"Authorization": f"Bearer {self.admin_token}"},
        )
        self.assertEqual(resp.status_code, 422, resp.text)

    # ------------------------------------------------------------------
    # 8. 颁发后 message 字段包含用户 ID 和次数
    # ------------------------------------------------------------------
    async def test_grant_quota_response_message_is_informative(self):
        resp = await self.client.post(
            f"/api/admin/users/{self.user_id}/grant-quota",
            json={"amount": 77},
            headers={"Authorization": f"Bearer {self.admin_token}"},
        )
        self.assertEqual(resp.status_code, 200)
        body = resp.json()
        msg = body.get("message", "")
        self.assertIn(str(self.user_id), msg)
        self.assertIn("77", msg)

    # ------------------------------------------------------------------
    # 9. portal-users 别名路径也可用
    # ------------------------------------------------------------------
    async def test_grant_quota_portal_users_alias_works(self):
        resp = await self.client.post(
            f"/api/admin/portal-users/{self.user_id}/grant-quota",
            json={"amount": 25},
            headers={"Authorization": f"Bearer {self.admin_token}"},
        )
        self.assertEqual(resp.status_code, 200, resp.text)
        self.assertEqual(resp.json()["granted"], 25)


class AdminGrantQuotaEndToEndTest(unittest.IsolatedAsyncioTestCase):
    """端到端：颁发额度后 solve 由 403 变 200（使用 mock token）"""

    async def asyncSetUp(self):
        self.env_patcher = patch.dict(
            os.environ, {"FCS_CLUSTER_ROLE": "standalone"}, clear=False
        )
        self.env_patcher.start()

        self.temp_dir = tempfile.TemporaryDirectory()
        self.db = Database(Path(self.temp_dir.name) / "e2e.sqlite3")
        await self.db.init_db()

        self.runtime = CaptchaRuntime(self.db)
        self.app = _make_app(self.db, self.runtime)

        self.client = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=self.app),
            base_url="http://testserver",
        )

        # 创建门户用户，quota=0
        ok, _msg, user_data = await self.db.create_portal_user(
            username="e2e_user",
            password="test-password",
            register_location="test",
        )
        self.assertTrue(ok, _msg)
        self.user_id = user_data["id"]

        # 为用户创建 API Key
        self.raw_portal_key, _ = await self.db.create_portal_user_api_key(
            portal_user_id=self.user_id,
            name="e2e-key",
        )

        self.admin_token = issue_admin_token()

    async def asyncTearDown(self):
        try:
            await self.client.aclose()
            await self.runtime.close()
            await self.db.close()
            for i in range(5):
                try:
                    self.temp_dir.cleanup()
                    break
                except (PermissionError, NotADirectoryError):
                    if i >= 4:
                        raise
                    await asyncio.sleep(0.05)
        finally:
            self.env_patcher.stop()

    async def test_zero_quota_returns_403_then_grant_enables_solve(self):
        # Step 1: quota=0 → 403
        with patch("src.api.service.config", SimpleNamespace(cluster_role="standalone")):
            resp = await self.client.post(
                "/api/v1/solve",
                json={"project_id": "test-proj", "action": "IMAGE_GENERATION"},
                headers={"Authorization": f"Bearer {self.raw_portal_key}"},
            )
        self.assertEqual(resp.status_code, 403, resp.text)
        self.assertIn("次数不足", resp.json().get("detail", ""))

        # Step 2: 管理员颁发额度
        grant_resp = await self.client.post(
            f"/api/admin/users/{self.user_id}/grant-quota",
            json={"amount": 2},
            headers={"Authorization": f"Bearer {self.admin_token}"},
        )
        self.assertEqual(grant_resp.status_code, 200, grant_resp.text)
        self.assertEqual(grant_resp.json()["item"]["quota_remaining"], 2)

        # Step 3: 颁发后 solve 成功（mock get_token）
        fake_result = SimpleNamespace(
            token="mocked-token-abc",
            browser_ref=42,
            browser_id=42,
            fingerprint={"userAgent": "test-agent"},
        )
        self.runtime._service_mode = "browser"
        fake_svc = SimpleNamespace(
            get_token=AsyncMock(return_value=fake_result),
            close=AsyncMock(),
        )
        self.runtime._browser_service = fake_svc

        with patch("src.api.service.config", SimpleNamespace(cluster_role="standalone")):
            with patch(
                "src.services.captcha_runtime.config",
                SimpleNamespace(
                    cluster_role="standalone",
                    captcha_method="browser",
                    node_name="test-node",
                    session_ttl_seconds=1200,
                ),
            ):
                resp2 = await self.client.post(
                    "/api/v1/solve",
                    json={"project_id": "test-proj", "action": "IMAGE_GENERATION"},
                    headers={"Authorization": f"Bearer {self.raw_portal_key}"},
                )
        self.assertEqual(resp2.status_code, 200, resp2.text)
        body2 = resp2.json()
        self.assertTrue(body2["success"])
        self.assertEqual(body2["token"], "mocked-token-abc")

        # Step 4: 验证额度已被消耗
        users_resp = await self.client.get(
            "/api/admin/users",
            headers={"Authorization": f"Bearer {self.admin_token}"},
        )
        items = users_resp.json()["items"]
        user_data = next(u for u in items if u["id"] == self.user_id)
        # 颁发了 2 次，消耗了 1 次，应剩 1
        self.assertEqual(user_data["quota_remaining"], 1)


if __name__ == "__main__":
    unittest.main()
