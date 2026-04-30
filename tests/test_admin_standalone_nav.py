"""
测试：standalone 角色下用户/CDK 管理 API 应可访问，
       集群/API Key 管理应被拒绝（仅 master 才能用）。

覆盖场景：
1. standalone 可调用 GET /api/admin/users → 200
2. standalone 可调用 POST /api/admin/portal-users（创建用户）→ 201
3. standalone 可调用 GET /api/admin/cdks → 200
4. standalone 可调用 POST /api/admin/users/{id}/grant-quota → 200
5. standalone 调用 GET /api/admin/cluster/nodes → 400（仅 master）
6. standalone 调用 GET /api/admin/api-keys → 400（仅 master）
7. subnode 调用 GET /api/admin/users → 400
8. subnode 调用 GET /api/admin/cdks → 400
9. master 调用 GET /api/admin/users → 200（确保 master 仍可用）
10. master 调用 GET /api/admin/cluster/nodes → 200
"""
import asyncio
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import httpx
from fastapi import FastAPI

from src.api import admin as admin_api
from src.api import service as service_api
from src.core.auth import issue_admin_token, set_database
from src.core.database import Database
from src.services.captcha_runtime import CaptchaRuntime


class _FakeCluster:
    """空集群对象，供测试用"""
    def __init__(self):
        self.nodes = {}

    async def dispatch_solve(self, *a, **kw):
        raise AssertionError("should not dispatch in standalone test")

    def decorate_nodes_capacity(self, nodes):
        return nodes or []


def _make_app(db: Database, runtime: CaptchaRuntime) -> FastAPI:
    cluster = _FakeCluster()
    app = FastAPI()
    admin_api.set_dependencies(db, runtime, cluster)
    service_api.set_dependencies(db, runtime, cluster)
    set_database(db)
    app.include_router(admin_api.router)
    app.include_router(service_api.router)
    return app


class StandaloneNavApiTests(unittest.IsolatedAsyncioTestCase):
    """验证 standalone 角色下各 API 的可访问性"""

    async def asyncSetUp(self):
        self.env_patcher = patch.dict(
            os.environ, {"FCS_CLUSTER_ROLE": "standalone"}, clear=False
        )
        self.env_patcher.start()

        self.temp_dir = tempfile.TemporaryDirectory()
        self.db = Database(Path(self.temp_dir.name) / "nav_test.sqlite3")
        await self.db.init_db()

        self.runtime = CaptchaRuntime(self.db)
        self.app = _make_app(self.db, self.runtime)

        self.client = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=self.app),
            base_url="http://testserver",
        )
        self.admin_token = issue_admin_token()

        # 创建一个测试用户，供 grant-quota 测试使用
        ok, _msg, user_data = await self.db.create_portal_user(
            username="nav_test_user",
            password="test-password",
            register_location="test",
        )
        self.assertTrue(ok, _msg)
        self.user_id = user_data["id"]

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

    def _auth(self):
        return {"Authorization": f"Bearer {self.admin_token}"}

    # ------------------------------------------------------------------
    # 1. standalone 可以列出门户用户
    # ------------------------------------------------------------------
    async def test_standalone_can_list_portal_users(self):
        resp = await self.client.get("/api/admin/users", headers=self._auth())
        self.assertEqual(resp.status_code, 200, resp.text)
        self.assertIn("items", resp.json())

    # ------------------------------------------------------------------
    # 2. standalone 可以通过 PATCH 更新门户用户信息
    # ------------------------------------------------------------------
    async def test_standalone_can_update_portal_user(self):
        resp = await self.client.patch(
            f"/api/admin/portal-users/{self.user_id}",
            json={"display_name": "已更新"},
            headers=self._auth(),
        )
        self.assertEqual(resp.status_code, 200, resp.text)
        self.assertEqual(resp.json()["item"]["display_name"], "已更新")

    # ------------------------------------------------------------------
    # 3. standalone 可以列出 CDK
    # ------------------------------------------------------------------
    async def test_standalone_can_list_cdks(self):
        resp = await self.client.get("/api/admin/cdks", headers=self._auth())
        self.assertEqual(resp.status_code, 200, resp.text)
        self.assertIn("items", resp.json())

    # ------------------------------------------------------------------
    # 4. standalone 可以颁发额度
    # ------------------------------------------------------------------
    async def test_standalone_can_grant_quota(self):
        resp = await self.client.post(
            f"/api/admin/users/{self.user_id}/grant-quota",
            json={"amount": 50},
            headers=self._auth(),
        )
        self.assertEqual(resp.status_code, 200, resp.text)
        self.assertEqual(resp.json()["granted"], 50)

    # ------------------------------------------------------------------
    # 5. standalone 调用集群节点接口 → 400（仅 master 可用）
    # ------------------------------------------------------------------
    async def test_standalone_cluster_nodes_returns_400(self):
        resp = await self.client.get("/api/admin/cluster/nodes", headers=self._auth())
        self.assertEqual(resp.status_code, 400, resp.text)
        self.assertIn("master", resp.json().get("detail", "").lower())

    # ------------------------------------------------------------------
    # 6. standalone 调用 API Key 接口 → 400（仅 master 可用）
    # ------------------------------------------------------------------
    async def test_standalone_api_keys_returns_400(self):
        resp = await self.client.get("/api/admin/apikeys", headers=self._auth())
        self.assertEqual(resp.status_code, 400, resp.text)
        self.assertIn("master", resp.json().get("detail", "").lower())


class SubnodeNavApiTests(unittest.IsolatedAsyncioTestCase):
    """验证 subnode 角色下用户/CDK API 被拒绝"""

    async def asyncSetUp(self):
        self.env_patcher = patch.dict(
            os.environ, {"FCS_CLUSTER_ROLE": "subnode"}, clear=False
        )
        self.env_patcher.start()

        self.temp_dir = tempfile.TemporaryDirectory()
        self.db = Database(Path(self.temp_dir.name) / "subnode_test.sqlite3")
        await self.db.init_db()

        self.runtime = CaptchaRuntime(self.db)
        self.app = _make_app(self.db, self.runtime)

        self.client = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=self.app),
            base_url="http://testserver",
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

    def _auth(self):
        return {"Authorization": f"Bearer {self.admin_token}"}

    # ------------------------------------------------------------------
    # 7. subnode 调用用户管理接口 → 400
    # ------------------------------------------------------------------
    async def test_subnode_cannot_list_portal_users(self):
        resp = await self.client.get("/api/admin/users", headers=self._auth())
        self.assertEqual(resp.status_code, 400, resp.text)
        self.assertIn("subnode", resp.json().get("detail", "").lower())

    # ------------------------------------------------------------------
    # 8. subnode 调用 CDK 接口 → 400
    # ------------------------------------------------------------------
    async def test_subnode_cannot_list_cdks(self):
        resp = await self.client.get("/api/admin/cdks", headers=self._auth())
        self.assertEqual(resp.status_code, 400, resp.text)
        self.assertIn("subnode", resp.json().get("detail", "").lower())


class MasterNavApiTests(unittest.IsolatedAsyncioTestCase):
    """验证 master 角色仍可正常访问用户/集群管理接口"""

    async def asyncSetUp(self):
        self.env_patcher = patch.dict(
            os.environ, {"FCS_CLUSTER_ROLE": "master"}, clear=False
        )
        self.env_patcher.start()

        self.temp_dir = tempfile.TemporaryDirectory()
        self.db = Database(Path(self.temp_dir.name) / "master_test.sqlite3")
        await self.db.init_db()

        self.runtime = CaptchaRuntime(self.db)
        self.app = _make_app(self.db, self.runtime)

        self.client = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=self.app),
            base_url="http://testserver",
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

    def _auth(self):
        return {"Authorization": f"Bearer {self.admin_token}"}

    # ------------------------------------------------------------------
    # 9. master 可以列出门户用户
    # ------------------------------------------------------------------
    async def test_master_can_list_portal_users(self):
        resp = await self.client.get("/api/admin/users", headers=self._auth())
        self.assertEqual(resp.status_code, 200, resp.text)
        self.assertIn("items", resp.json())

    # ------------------------------------------------------------------
    # 10. master 可以调用集群节点接口
    # ------------------------------------------------------------------
    async def test_master_can_list_cluster_nodes(self):
        resp = await self.client.get("/api/admin/cluster/nodes", headers=self._auth())
        self.assertEqual(resp.status_code, 200, resp.text)
